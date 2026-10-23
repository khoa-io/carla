(() => {
  const canvas = document.getElementById('camera');
  const context = canvas.getContext('2d', { alpha: false });
  const dot = document.getElementById('connection-dot');
  const connectionStatus = document.getElementById('connection-status');
  const frameInfo = document.getElementById('frame-info');
  const emptyState = document.getElementById('empty-state');
  const takeControl = document.getElementById('take-control');
  const controlMessage = document.getElementById('control-message');
  const vehicleStatus = document.getElementById('vehicle-status');
  const buttons = [...document.querySelectorAll('[data-key]')];
  const pressed = new Set();
  const wsUrl = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;
  let socket;
  let connected = false;
  let controller = false;
  let armed = false;
  let lastFrame = -1;
  let sequence = 0;
  let forceBrake = false;
  let pendingFrame = null;
  let decodingFrame = false;

  function setConnection(state, text) {
    dot.className = state;
    connectionStatus.textContent = text;
    takeControl.disabled = !connected;
  }

  function connect() {
    socket = new WebSocket(wsUrl);
    socket.binaryType = 'arraybuffer';
    socket.onopen = () => {
      connected = true;
      setConnection('ready', 'Connected');
      const token = document.querySelector('meta[name="carla-web-token"]').content;
      socket.send(JSON.stringify({ type: 'auth', token }));
    };
    socket.onclose = () => {
      connected = false;
      controller = false;
      armed = false;
      pressed.clear();
      syncButtons();
      setConnection('error', 'Disconnected');
      controlMessage.textContent = 'Connection lost. The adapter should brake; reconnect and take control again.';
      window.setTimeout(connect, 1500);
    };
    socket.onerror = () => setConnection('error', 'Connection error');
    socket.onmessage = event => {
      if (typeof event.data === 'string') {
        let message;
        try { message = JSON.parse(event.data); } catch (_) { return; }
        if (message.type === 'status') {
          connectionStatus.textContent = message.status;
          const ready = message.status.toLowerCase().includes('connected') || message.status === 'Streaming camera';
          dot.className = ready ? 'ready' : '';
          takeControl.disabled = !connected;
          if (message.status.startsWith('Connected; spawned ')) vehicleStatus.textContent = message.status.slice('Connected; spawned '.length);
          if (message.status.includes('timed out')) {
            armed = false;
            takeControl.textContent = controller ? 'Re-arm' : 'Take control';
            controlMessage.textContent = message.status;
          }
        } else if (message.type === 'control_status') {
          controller = message.controller;
          armed = message.armed;
          controlMessage.textContent = message.message;
          takeControl.textContent = controller ? (armed ? 'Release control' : 'Re-arm') : 'Take control';
          if (controller) sendControl();
        }
      } else if (event.data instanceof ArrayBuffer) {
        pendingFrame = event.data;
        if (!decodingFrame) drainFrames();
      }
    };
  }

  async function drainFrames() {
    decodingFrame = true;
    while (pendingFrame) {
      const frameBytes = pendingFrame;
      pendingFrame = null;
      await drawFrame(new DataView(frameBytes), new Uint8Array(frameBytes));
    }
    decodingFrame = false;
  }

  async function drawFrame(view, bytes) {
    if (bytes.byteLength < 32) return;
    const frame = Number(view.getBigUint64(0, false));
    const width = view.getUint32(8, false);
    const height = view.getUint32(12, false);
    const timestamp = view.getFloat64(16, false);
    if (!width || !height || bytes.byteLength <= 32 || frame < lastFrame) return;
    let bitmap;
    try { bitmap = await createImageBitmap(new Blob([bytes.subarray(32)], { type: 'image/jpeg' })); }
    catch (_) { return; }
    if (frame < lastFrame) { bitmap.close(); return; }
    canvas.width = width;
    canvas.height = height;
    context.drawImage(bitmap, 0, 0, width, height);
    bitmap.close();
    emptyState.style.display = 'none';
    frameInfo.textContent = `Frame ${frame} · ${width} × ${height} · sim ${timestamp.toFixed(2)} s`;
    lastFrame = frame;
  }

  function sendControl() {
    if (!socket || socket.readyState !== WebSocket.OPEN || !controller || !armed) return;
    const throttle = pressed.has('w') && !pressed.has('s') && !forceBrake ? 0.55 : 0;
    const brake = pressed.has('s') || forceBrake ? 1 : 0;
    const steer = (pressed.has('a') ? -0.65 : 0) + (pressed.has('d') ? 0.65 : 0);
    socket.send(JSON.stringify({ type: 'control', seq: ++sequence, displayed_frame: Math.max(0, lastFrame), throttle, steer, brake }));
  }

  function syncButtons() {
    for (const button of buttons) button.classList.toggle('active', pressed.has(button.dataset.key));
  }

  function press(key, isDown) {
    if (!['w', 'a', 's', 'd'].includes(key)) return;
    if (isDown) { forceBrake = false; pressed.add(key); } else pressed.delete(key);
    syncButtons();
    sendControl();
  }

  takeControl.addEventListener('click', () => {
    if (!connected) return;
    if (controller && armed) {
      socket.send(JSON.stringify({ type: 'release' }));
      controller = false;
      armed = false;
      pressed.clear();
      syncButtons();
      takeControl.textContent = 'Take control';
      controlMessage.textContent = 'Control released; vehicle braking.';
    } else {
      socket.send(JSON.stringify({ type: 'take_control' }));
    }
  });

  window.addEventListener('keydown', event => {
    const key = event.key.toLowerCase();
    if (['w', 'a', 's', 'd'].includes(key)) event.preventDefault();
    if (['w', 'a', 's', 'd'].includes(key)) forceBrake = false;
    press(key, true);
  });
  window.addEventListener('keyup', event => press(event.key.toLowerCase(), false));
  window.addEventListener('blur', () => { pressed.clear(); forceBrake = true; syncButtons(); sendControl(); });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { pressed.clear(); forceBrake = true; syncButtons(); sendControl(); }
  });
  for (const button of buttons) {
    const key = button.dataset.key;
    button.addEventListener('pointerdown', event => { event.preventDefault(); press(key, true); });
    for (const name of ['pointerup', 'pointerleave', 'pointercancel']) button.addEventListener(name, () => press(key, false));
  }
  window.setInterval(sendControl, 50);
  setConnection('', 'Connecting…');
  connect();
})();
