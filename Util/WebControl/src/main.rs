use std::{
    env,
    net::SocketAddr,
    process::Stdio,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

use axum::{
    body::Bytes,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::{header, HeaderMap, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::get,
    Router,
};
use futures_util::{SinkExt, StreamExt};
use jpeg_encoder::{ColorType, Encoder};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    process::{Child, Command},
    sync::watch,
};

const INDEX_HTML: &str = include_str!("../web/index.html");
const APP_JS: &str = include_str!("../web/app.js");
const STYLE_CSS: &str = include_str!("../web/style.css");
const MAX_IPC_RECORD: usize = 64 * 1024 * 1024;
const MAX_CONTROL_FRAME_LAG: u64 = 8;
const MAX_CONTROL_FRAME_AGE: Duration = Duration::from_millis(750);

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Control {
    throttle: f32,
    steer: f32,
    brake: f32,
    armed: bool,
    shutdown: bool,
}

impl Control {
    fn safe_stop() -> Self {
        Self {
            throttle: 0.0,
            steer: 0.0,
            brake: 1.0,
            armed: false,
            shutdown: false,
        }
    }

    fn clamp(&mut self) {
        self.throttle = finite_clamp(self.throttle, 0.0, 1.0);
        self.steer = finite_clamp(self.steer, -1.0, 1.0);
        self.brake = finite_clamp(self.brake, 0.0, 1.0);
    }
}

impl Default for Control {
    fn default() -> Self {
        Self::safe_stop()
    }
}

fn finite_clamp(value: f32, low: f32, high: f32) -> f32 {
    if value.is_finite() {
        value.clamp(low, high)
    } else {
        low
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum BrowserCommand {
    Auth {
        token: String,
    },
    TakeControl,
    Control {
        seq: u64,
        displayed_frame: u64,
        throttle: f32,
        steer: f32,
        brake: f32,
    },
    Release,
}

#[derive(Clone)]
struct AppState {
    frames: watch::Receiver<Option<Bytes>>,
    status: watch::Receiver<String>,
    control_tx: watch::Sender<Control>,
    controller: Arc<AtomicU64>,
    armed: Arc<std::sync::atomic::AtomicBool>,
    next_client: Arc<AtomicU64>,
    latest_frame: Arc<AtomicU64>,
    latest_frame_at: Arc<std::sync::Mutex<Option<Instant>>>,
    adapter_connected: Arc<std::sync::atomic::AtomicBool>,
    shutdown: watch::Receiver<bool>,
    browser_token: Arc<String>,
    web_origin: Arc<String>,
}

#[derive(Debug)]
struct Settings {
    carla_host: String,
    carla_port: u16,
    web_port: u16,
    python: String,
    vehicle: String,
    width: u32,
    height: u32,
}

impl Settings {
    fn parse() -> Result<Self, String> {
        let mut settings = Self {
            carla_host: "127.0.0.1".into(),
            carla_port: 2000,
            web_port: 8765,
            python: "python3".into(),
            vehicle: "vehicle.tesla.model3".into(),
            width: 640,
            height: 360,
        };
        let mut args = env::args().skip(1);
        while let Some(arg) = args.next() {
            if arg == "--help" || arg == "-h" {
                return Err("usage: carla-web-control [--carla-host HOST] [--carla-port PORT] [--web-port PORT] [--python PATH] [--vehicle BLUEPRINT] [--width PX] [--height PX]".into());
            }
            let value = args
                .next()
                .ok_or_else(|| format!("missing value for {arg}"))?;
            match arg.as_str() {
                "--carla-host" => settings.carla_host = value,
                "--carla-port" => {
                    settings.carla_port = value
                        .parse()
                        .map_err(|_| "invalid --carla-port".to_string())?
                }
                "--web-port" => {
                    settings.web_port = value
                        .parse()
                        .map_err(|_| "invalid --web-port".to_string())?
                }
                "--python" => settings.python = value,
                "--vehicle" => settings.vehicle = value,
                "--width" => {
                    settings.width = value.parse().map_err(|_| "invalid --width".to_string())?
                }
                "--height" => {
                    settings.height = value.parse().map_err(|_| "invalid --height".to_string())?
                }
                _ => return Err(format!("unknown option: {arg}")),
            }
        }
        if settings.width == 0
            || settings.height == 0
            || (settings.width as u64 * settings.height as u64) > 8_294_400
        {
            return Err(
                "camera dimensions must be nonzero and no larger than 3840x2160 total pixels"
                    .into(),
            );
        }
        Ok(settings)
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let settings = match Settings::parse() {
        Ok(settings) => settings,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };

    let web_addr = SocketAddr::from(([127, 0, 0, 1], settings.web_port));
    let mut browser_secret = [0u8; 32];
    let mut ipc_secret = [0u8; 32];
    getrandom::fill(&mut browser_secret)?;
    getrandom::fill(&mut ipc_secret)?;
    let browser_token = hex(&browser_secret);
    let ipc_token = hex(&ipc_secret);

    let web_listener = TcpListener::bind(web_addr).await?;
    let web_addr = web_listener.local_addr()?;
    let web_origin = format!("http://{web_addr}");

    let (ipc_listener, ipc_port) = {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        (listener, port)
    };
    let adapter_path = concat!(env!("CARGO_MANIFEST_DIR"), "/adapter/carla_adapter.py");
    let mut adapter = spawn_adapter(&settings, adapter_path, ipc_port, &ipc_token)?;
    eprintln!("Waiting for CARLA adapter on 127.0.0.1:{ipc_port}...");
    let mut stream =
        match tokio::time::timeout(Duration::from_secs(45), ipc_listener.accept()).await {
            Ok(Ok((stream, _))) => stream,
            Ok(Err(error)) => return Err(error.into()),
            Err(_) => {
                let _ = adapter.kill().await;
                return Err("timed out waiting for the CARLA adapter".into());
            }
        };

    let mut handshake = [0u8; 4];
    match tokio::time::timeout(Duration::from_secs(5), stream.read_exact(&mut handshake)).await {
        Ok(Ok(_)) => {}
        _ => {
            let _ = adapter.kill().await;
            return Err("invalid adapter handshake".into());
        }
    }
    let handshake_len = u32::from_be_bytes(handshake) as usize;
    if handshake_len > 256 || handshake_len < 1 {
        let _ = adapter.kill().await;
        return Err("invalid adapter handshake length".into());
    }
    let mut handshake = vec![0u8; handshake_len];
    stream.read_exact(&mut handshake).await?;
    let expected: Vec<u8> = [b'H']
        .into_iter()
        .chain(ipc_token.as_bytes().iter().copied())
        .collect();
    if handshake != expected {
        let _ = adapter.kill().await;
        return Err("adapter capability check failed".into());
    }

    let (frame_tx, frame_rx) = watch::channel(None);
    let (status_tx, status_rx) = watch::channel("Connecting to CARLA".to_string());
    let (control_tx, control_rx) = watch::channel(Control::safe_stop());
    let controller = Arc::new(AtomicU64::new(0));
    let armed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let shutdown_controller = controller.clone();
    let shutdown_armed = armed.clone();
    let latest_frame = Arc::new(AtomicU64::new(0));
    let latest_frame_at = Arc::new(std::sync::Mutex::new(None));
    let adapter_connected = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    let (reader, writer) = stream.into_split();
    tokio::spawn(adapter_writer(writer, control_rx, shutdown_rx.clone()));
    let (raw_frame_tx, raw_frame_rx) = watch::channel(None);
    tokio::spawn(adapter_reader(
        reader,
        raw_frame_tx,
        status_tx.clone(),
        armed.clone(),
        control_tx.clone(),
        adapter_connected.clone(),
    ));
    tokio::spawn(encode_latest_frames(
        raw_frame_rx,
        frame_tx,
        status_tx,
        latest_frame.clone(),
        latest_frame_at.clone(),
    ));

    let state = AppState {
        frames: frame_rx,
        status: status_rx,
        control_tx: control_tx.clone(),
        controller,
        armed,
        next_client: Arc::new(AtomicU64::new(1)),
        latest_frame,
        latest_frame_at,
        adapter_connected,
        shutdown: shutdown_rx,
        browser_token: Arc::new(browser_token),
        web_origin: Arc::new(web_origin.clone()),
    };
    let app = Router::new()
        .route("/", get(index))
        .route("/app.js", get(javascript))
        .route("/style.css", get(stylesheet))
        .route("/healthz", get(health))
        .route("/ws", get(websocket))
        .with_state(state);

    eprintln!("CARLA web control available at {web_origin}");
    let shutdown_signal = shutdown_tx.clone();
    let signal_control = control_tx.clone();
    let signal_controller = shutdown_controller.clone();
    let signal_armed = shutdown_armed.clone();
    let serve = axum::serve(web_listener, app).with_graceful_shutdown(async move {
        let _ = tokio::signal::ctrl_c().await;
        signal_armed.store(false, Ordering::Release);
        signal_controller.store(0, Ordering::Release);
        signal_control.send_replace(Control::safe_stop());
        shutdown_signal.send_replace(true);
    });
    let result = serve.await;
    shutdown_armed.store(false, Ordering::Release);
    shutdown_controller.store(0, Ordering::Release);
    control_tx.send_replace(Control::safe_stop());
    shutdown_tx.send_replace(true);
    if tokio::time::timeout(Duration::from_secs(15), adapter.wait())
        .await
        .is_err()
    {
        let _ = adapter.kill().await;
    }
    result?;
    Ok(())
}

fn spawn_adapter(
    settings: &Settings,
    script: &str,
    ipc_port: u16,
    ipc_token: &str,
) -> Result<Child, std::io::Error> {
    Command::new(&settings.python)
        .arg(script)
        .env("CARLA_WEB_IPC_ADDR", format!("127.0.0.1:{ipc_port}"))
        .env("CARLA_WEB_IPC_TOKEN", ipc_token)
        .env("CARLA_WEB_HOST", &settings.carla_host)
        .env("CARLA_WEB_PORT", settings.carla_port.to_string())
        .env("CARLA_WEB_VEHICLE", &settings.vehicle)
        .env("CARLA_WEB_WIDTH", settings.width.to_string())
        .env("CARLA_WEB_HEIGHT", settings.height.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        result.push(DIGITS[(byte >> 4) as usize] as char);
        result.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    result
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

async fn adapter_writer(
    mut stream: tokio::net::tcp::OwnedWriteHalf,
    mut controls: watch::Receiver<Control>,
    mut shutdown: watch::Receiver<bool>,
) {
    loop {
        let current = tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow_and_update() {
                    Control { shutdown: true, ..Control::safe_stop() }
                } else {
                    continue;
                }
            }
            changed = controls.changed() => {
                if changed.is_err() { break; }
                controls.borrow_and_update().clone()
            }
        };
        let json = match serde_json::to_vec(&current) {
            Ok(json) => json,
            Err(_) => break,
        };
        let mut record = Vec::with_capacity(json.len() + 1);
        record.push(b'C');
        record.extend_from_slice(&json);
        if write_record(&mut stream, &record).await.is_err() {
            break;
        }
        if current.shutdown {
            break;
        }
    }
}

async fn adapter_reader(
    mut stream: tokio::net::tcp::OwnedReadHalf,
    frames: watch::Sender<Option<Vec<u8>>>,
    status: watch::Sender<String>,
    armed: Arc<std::sync::atomic::AtomicBool>,
    controls: watch::Sender<Control>,
    adapter_connected: Arc<std::sync::atomic::AtomicBool>,
) {
    loop {
        let mut len = [0u8; 4];
        if stream.read_exact(&mut len).await.is_err() {
            break;
        }
        let len = u32::from_be_bytes(len) as usize;
        if !(1..=MAX_IPC_RECORD).contains(&len) {
            break;
        }
        let mut record = vec![0u8; len];
        if stream.read_exact(&mut record).await.is_err() {
            break;
        }
        match record[0] {
            b'F' => {
                frames.send_replace(Some(record[1..].to_vec()));
            }
            b'S' => {
                let text = String::from_utf8_lossy(&record[1..]).to_string();
                status.send_replace(text);
            }
            b'D' => {
                armed.store(false, Ordering::Release);
                controls.send_replace(Control::safe_stop());
                let text = String::from_utf8_lossy(&record[1..]).to_string();
                status.send_replace(text);
            }
            _ => {}
        }
    }
    adapter_connected.store(false, Ordering::Release);
    armed.store(false, Ordering::Release);
    controls.send_replace(Control::safe_stop());
    status.send_replace("CARLA adapter disconnected".to_string());
    frames.send_replace(None);
}

async fn encode_latest_frames(
    mut raw_frames: watch::Receiver<Option<Vec<u8>>>,
    frames: watch::Sender<Option<Bytes>>,
    status: watch::Sender<String>,
    latest_frame: Arc<AtomicU64>,
    latest_frame_at: Arc<std::sync::Mutex<Option<Instant>>>,
) {
    loop {
        if raw_frames.changed().await.is_err() {
            break;
        }
        let Some(raw) = raw_frames.borrow_and_update().clone() else {
            continue;
        };
        let encoded = tokio::task::spawn_blocking(move || jpeg_packet(&raw)).await;
        match encoded {
            Ok(Some(packet)) => {
                let frame_id = u64::from_be_bytes(packet[..8].try_into().unwrap_or([0; 8]));
                latest_frame.store(frame_id, Ordering::Release);
                *latest_frame_at.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
                frames.send_replace(Some(Bytes::from(packet)));
            }
            Ok(None) => {}
            Err(error) => {
                status.send_replace(format!("Camera encoder failed: {error}"));
            }
        }
    }
}

fn jpeg_packet(frame: &[u8]) -> Option<Vec<u8>> {
    // Header: frame id (u64), width/height (u32), simulation timestamp (f64), receive monotonic ns (u64).
    if frame.len() < 32 {
        return None;
    }
    let width = u32::from_be_bytes(frame[8..12].try_into().ok()?);
    let height = u32::from_be_bytes(frame[12..16].try_into().ok()?);
    let pixels = frame.get(32..)?;
    let expected = (width as usize)
        .checked_mul(height as usize)?
        .checked_mul(4)?;
    if width == 0
        || height == 0
        || width > u16::MAX as u32
        || height > u16::MAX as u32
        || pixels.len() != expected
    {
        return None;
    }
    let mut rgb = Vec::with_capacity(expected / 4 * 3);
    for bgra in pixels.chunks_exact(4) {
        rgb.extend_from_slice(&[bgra[2], bgra[1], bgra[0]]);
    }
    let mut jpeg = Vec::new();
    Encoder::new(&mut jpeg, 82)
        .encode(&rgb, width as u16, height as u16, ColorType::Rgb)
        .ok()?;
    let mut packet = Vec::with_capacity(32 + jpeg.len());
    packet.extend_from_slice(&frame[..32]);
    packet.extend_from_slice(&jpeg);
    Some(packet)
}

async fn write_record(
    stream: &mut tokio::net::tcp::OwnedWriteHalf,
    payload: &[u8],
) -> std::io::Result<()> {
    stream
        .write_all(&(payload.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(payload).await
}

async fn index(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    let expected_host = state.web_origin.strip_prefix("http://").unwrap_or_default();
    if headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        != Some(expected_host)
    {
        return (
            StatusCode::FORBIDDEN,
            [(header::CACHE_CONTROL, "no-store")],
            Html(String::from("Invalid Host header")),
        )
            .into_response();
    }
    let html = INDEX_HTML.replace("__CARLA_WEB_TOKEN__", state.browser_token.as_str());
    (
        [
            (header::CACHE_CONTROL, "no-store"),
            (header::CONTENT_SECURITY_POLICY, "default-src 'self'; img-src 'self' blob:; connect-src 'self' ws:; script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        ],
        Html(html),
    ).into_response()
}
async fn javascript() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        APP_JS,
    )
}
async fn stylesheet() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
        STYLE_CSS,
    )
}
async fn health(State(state): State<AppState>) -> impl IntoResponse {
    let status = state.status.borrow().clone();
    let frame_fresh = state.adapter_connected.load(Ordering::Acquire)
        && state
            .latest_frame_at
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_some_and(|at| at.elapsed() <= MAX_CONTROL_FRAME_AGE);
    let code = if frame_fresh {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (code, status)
}

async fn websocket(
    State(state): State<AppState>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    let origin = headers
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok());
    if origin != Some(state.web_origin.as_str()) {
        return (StatusCode::FORBIDDEN, "WebSocket origin rejected").into_response();
    }
    let id = state.next_client.fetch_add(1, Ordering::Relaxed);
    upgrade
        .max_message_size(4096)
        .max_frame_size(4096)
        .on_upgrade(move |socket| handle_socket(socket, state, id))
}

async fn handle_socket(socket: WebSocket, state: AppState, id: u64) {
    let (mut send, mut receive) = socket.split();
    let authorized = match tokio::time::timeout(Duration::from_secs(5), receive.next()).await {
        Ok(Some(Ok(Message::Text(text)))) => match serde_json::from_str::<BrowserCommand>(&text) {
            Ok(BrowserCommand::Auth { token }) => {
                constant_time_eq(token.as_bytes(), state.browser_token.as_bytes())
            }
            _ => false,
        },
        _ => false,
    };
    if !authorized {
        return;
    }
    let mut frames = state.frames.clone();
    let mut status = state.status.clone();
    let mut shutdown = state.shutdown.clone();
    let mut last_sequence = 0u64;
    let mut last_control_at = Instant::now() - Duration::from_secs(1);
    let hello = serde_json::json!({"type":"status", "status": status.borrow().clone(), "controller": false, "armed": false});
    if send
        .send(Message::Text(hello.to_string().into()))
        .await
        .is_err()
    {
        return;
    }

    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow_and_update() { break; }
            }
            changed = frames.changed() => {
                if changed.is_err() { break; }
                let packet = { frames.borrow_and_update().clone() };
                if let Some(packet) = packet {
                    if !matches!(tokio::time::timeout(Duration::from_secs(2), send.send(Message::Binary(packet))).await, Ok(Ok(()))) { break; }
                }
            }
            changed = status.changed() => {
                if changed.is_err() { break; }
                let message = serde_json::json!({"type":"status", "status": status.borrow_and_update().clone(), "controller": state.controller.load(Ordering::Relaxed) == id, "armed": state.armed.load(Ordering::Acquire)});
                if !matches!(tokio::time::timeout(Duration::from_secs(2), send.send(Message::Text(message.to_string().into()))).await, Ok(Ok(()))) { break; }
            }
            message = receive.next() => {
                let Some(Ok(Message::Text(text))) = message else { break; };
                let Ok(command) = serde_json::from_str::<BrowserCommand>(&text) else { continue; };
                match command {
                    BrowserCommand::Auth { .. } => {}
                    BrowserCommand::TakeControl => {
                        let acquired = state.controller.compare_exchange(0, id, Ordering::AcqRel, Ordering::Relaxed).is_ok()
                            || state.controller.load(Ordering::Acquire) == id;
        let fresh = state.adapter_connected.load(Ordering::Acquire)
            && state.latest_frame_at.lock().unwrap_or_else(|e| e.into_inner())
                .is_some_and(|at| at.elapsed() <= MAX_CONTROL_FRAME_AGE);
                        let acquired = acquired && fresh;
                        if acquired {
                            state.armed.store(true, Ordering::Release);
                            state.control_tx.send_replace(Control { armed: true, throttle: 0.0, steer: 0.0, brake: 1.0, shutdown: false });
                        } else if state.controller.load(Ordering::Acquire) == id {
                            state.armed.store(false, Ordering::Release);
                            state.control_tx.send_replace(Control::safe_stop());
                        }
                        let message = if !fresh {"Camera is not receiving fresh frames; control remains disabled."} else if acquired {"Control enabled"} else {"Another browser owns control"};
                        let response = serde_json::json!({"type":"control_status", "controller": state.controller.load(Ordering::Acquire) == id, "armed": acquired, "message": message});
                        if !matches!(tokio::time::timeout(Duration::from_secs(2), send.send(Message::Text(response.to_string().into()))).await, Ok(Ok(()))) { break; }
                    }
                    BrowserCommand::Control { seq, displayed_frame, throttle, steer, brake } => {
                        if state.controller.load(Ordering::Acquire) == id && state.armed.load(Ordering::Acquire) {
                            let current_frame = state.latest_frame.load(Ordering::Acquire);
                            let frame_fresh = state.adapter_connected.load(Ordering::Acquire)
                                && state.latest_frame_at.lock().unwrap_or_else(|e| e.into_inner())
                                .is_some_and(|at| at.elapsed() <= MAX_CONTROL_FRAME_AGE);
                            if !frame_fresh || current_frame == 0 || displayed_frame == 0 || displayed_frame > current_frame || seq <= last_sequence || current_frame.saturating_sub(displayed_frame) > MAX_CONTROL_FRAME_LAG {
                                state.armed.store(false, Ordering::Release);
                                state.control_tx.send_replace(Control::safe_stop());
                                let message = serde_json::json!({"type":"control_status", "controller": true, "armed": false, "message":"Camera is stale or command sequence is invalid; take control again."});
                                if !matches!(tokio::time::timeout(Duration::from_secs(2), send.send(Message::Text(message.to_string().into()))).await, Ok(Ok(()))) { break; }
                                continue;
                            }
                            if last_control_at.elapsed() < Duration::from_millis(25) { continue; }
                            last_sequence = seq;
                            last_control_at = Instant::now();
                            let mut control = Control { throttle, steer, brake, armed: true, shutdown: false };
                            if control.brake > 0.0 { control.throttle = 0.0; }
                            control.clamp();
                            state.control_tx.send_replace(control);
                        }
                    }
                    BrowserCommand::Release => {
                        if state.controller.compare_exchange(id, 0, Ordering::AcqRel, Ordering::Relaxed).is_ok() {
                            state.armed.store(false, Ordering::Release);
                            state.control_tx.send_replace(Control::safe_stop());
                        }
                    }
                }
            }
        }
    }

    if state
        .controller
        .compare_exchange(id, 0, Ordering::AcqRel, Ordering::Relaxed)
        .is_ok()
    {
        state.armed.store(false, Ordering::Release);
        state.control_tx.send_replace(Control::safe_stop());
    }
}
