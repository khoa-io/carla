// Copyright (c) 2017 Computer Vision Center (CVC) at the Universitat Autonoma
// de Barcelona (UAB).
//
// This work is licensed under the terms of the MIT license.
// For a copy, see <https://opensource.org/licenses/MIT>.

#include "Carla.h"
#include "Carla/Sensor/PixelReader.h"

#include "Engine/TextureRenderTarget2D.h"
#include "Async/Async.h"
#include "HighResScreenshot.h"
#include "HAL/IConsoleManager.h"
#include "EngineGlobals.h"
#include "RenderCore.h"
#include "Misc/CoreDelegates.h"
#include "Runtime/ImageWriteQueue/Public/ImageWriteQueue.h"

#include <deque>

struct FPixelReaderReadbackRing
{
  struct FPending
  {
    std::shared_ptr<FRHIGPUTextureReadback> Readback;
    std::function<void(FRHICommandListImmediate &)> Complete;
  };
  TArray<std::shared_ptr<FRHIGPUTextureReadback>> Slots;
  std::deque<FPending> Pending;
  FIntPoint Size;
  EPixelFormat Format;
  FDelegateHandle EndFrameHandle;
  uint64 Submitted = 0;
  uint64 Completed = 0;
  uint64 Saturated = 0;
  size_t HighWater = 0;

  void Poll(FRHICommandListImmediate &Cmd, bool Drain = false)
  {
    check(IsInRenderingThread());
    while (!Pending.empty() && (Drain || Pending.front().Readback->IsReady()))
    {
      auto Item = std::move(Pending.front());
      Pending.pop_front();
      Item.Complete(Cmd);
      ++Completed;
    }
  }

  std::shared_ptr<FRHIGPUTextureReadback> Acquire(FRHICommandListImmediate &Cmd)
  {
    Poll(Cmd);
    for (auto &Slot : Slots)
    {
      if (Slot.use_count() == 1) return Slot;
    }
    // Bounded backpressure: never overwrite a GPU slot or silently skip a frame.
    ++Saturated;
    Cmd.SubmitCommandsAndFlushGPU();
    Cmd.BlockUntilGPUIdle();
    Poll(Cmd);
    for (auto &Slot : Slots)
    {
      if (Slot.use_count() == 1) return Slot;
    }
    checkNoEntry();
    return nullptr;
  }
};

namespace
{
  // Keep the established behavior until same-binary A/B measurements justify
  // changing it. Other RHIs always retain the original workaround.
  TAutoConsoleVariable<int32> CVarCarlaMetalBlockingQuery(
      TEXT("carla.Camera.MetalBlockingQuery"), 1,
      TEXT("Use the legacy blocking readback query on Metal (1), or the readback fence only (0)."),
      ECVF_RenderThreadSafe);
  TAutoConsoleVariable<int32> CVarCarlaReadbackDiagnostics(
      TEXT("carla.Camera.ReadbackDiagnostics"), 0,
      TEXT("Log per-readback exclusive CPU phase milliseconds and effective rendering settings. Diagnostic overhead affects throughput."),
      ECVF_RenderThreadSafe);
  TAutoConsoleVariable<int32> CVarCarlaReadbackSlots(
      TEXT("carla.Camera.ReadbackSlots"), 0,
      TEXT("Metal camera persistent readback slots: 0=fresh per capture, 2 or 3=bounded ordered ring. Set before spawning sensors."),
      ECVF_RenderThreadSafe);

  struct FReadbackTimings
  {
    uint64 Sequence = 0;
    uint64 Frame = 0;
    double Started = 0.0;
    double Create = 0.0;
    double Copy = 0.0;
    double Query = 0.0;
    double Flush = 0.0;
    double QueryWait = 0.0;
    double ReadyWait = 0.0;
    double MapQueued = 0.0;
    double Map = 0.0;
    double Payload = 0.0;
    double Unmap = 0.0;
    bool BlockingQuery = true;
  };
}

// =============================================================================
// -- FPixelReader -------------------------------------------------------------
// =============================================================================

void FPixelReader::WritePixelsToBuffer(
    const UTextureRenderTarget2D &RenderTarget,
    uint32 Offset,
    FRHICommandListImmediate &RHICmdList,
    FPixelReader::Payload FuncForSending,
    uint64 CaptureFrame)
{
  auto *Resource = static_cast<FTextureRenderTarget2DResource *>(RenderTarget.Resource);
  if (Resource != nullptr)
  {
    WritePixelsToBuffer(*Resource, Offset, RHICmdList, std::move(FuncForSending), CaptureFrame, nullptr);
  }
}

void FPixelReader::WritePixelsToBuffer(
    FTextureRenderTargetResource &RenderResource,
    uint32 Offset,
    FRHICommandListImmediate &RHICmdList,
    FPixelReader::Payload FuncForSending,
    uint64 CaptureFrame,
    std::shared_ptr<FPixelReaderReadbackState> State,
    bool SynchronousCapture)
{
  TRACE_CPUPROFILER_EVENT_SCOPE_STR("WritePixelsToBuffer");
  check(IsInRenderingThread());

  FTexture2DRHIRef Texture = RenderResource.GetRenderTargetTexture();
  if (!Texture)
  {
    return;
  }

  const bool Diagnostics = CVarCarlaReadbackDiagnostics.GetValueOnRenderThread() != 0;
  const bool BlockingQuery = !IsMetalPlatform(GMaxRHIShaderPlatform) ||
      CVarCarlaMetalBlockingQuery.GetValueOnRenderThread() != 0;
  FReadbackTimings Timings;
  if (Diagnostics)
  {
    static uint64 Sequence = 0;
    Timings.Sequence = ++Sequence;
    Timings.Frame = CaptureFrame;
    Timings.Started = FPlatformTime::Seconds();
    Timings.BlockingQuery = BlockingQuery;
    if (Sequence == 1)
    {
      UE_LOG(LogCarla, Display, TEXT("CarlaCameraSettings rhi=%s editor=%d rhi_thread=%d rhi_task=%d bypass=%d query=%d vsync=%d maxfps=%.3f screenpercentage=%.1f"),
          GDynamicRHI->GetName(), GIsEditor, IsRunningRHIInSeparateThread(), IsRunningRHIInTaskThread(), RHICmdList.Bypass(), BlockingQuery,
          IConsoleManager::Get().FindConsoleVariable(TEXT("r.VSync"))->GetInt(),
          IConsoleManager::Get().FindConsoleVariable(TEXT("t.MaxFPS"))->GetFloat(),
          IConsoleManager::Get().FindConsoleVariable(TEXT("r.ScreenPercentage"))->GetFloat());
      UE_LOG(LogCarla, Display, TEXT("CarlaCameraReadback columns=sequence,frame,start_seconds,query_enabled,create_ms,copy_enqueue_ms,query_create_end_ms,rhi_flush_ms,query_wait_ms,ready_task_wait_ms,map_queue_ms,map_ms,payload_ms,unmap_ms,total_ms,game_ms,render_ms,rhi_ms,gpu_ms,mapped"));
    }
  }
  std::shared_ptr<FPixelReaderReadbackRing> Ring;
  const int32 SlotCount = CVarCarlaReadbackSlots.GetValueOnRenderThread();
  if (State && IsMetalPlatform(GMaxRHIShaderPlatform) && SlotCount > 0)
  {
    if (!State->Ring)
    {
      State->Ring = std::make_shared<FPixelReaderReadbackRing>();
      std::weak_ptr<FPixelReaderReadbackState> WeakState = State;
      State->Ring->EndFrameHandle = FCoreDelegates::OnEndFrameRT.AddLambda([WeakState]()
      {
        auto Pinned = WeakState.lock();
        if (Pinned && Pinned->Ring)
        {
          Pinned->Ring->Poll(FRHICommandListExecutor::GetImmediateCommandList());
        }
      });
    }
    Ring = State->Ring;
    if (Ring->Slots.Num() == 0 || Ring->Size != Texture->GetSizeXY() || Ring->Format != Texture->GetFormat())
    {
      if (!Ring->Pending.empty())
      {
        RHICmdList.SubmitCommandsAndFlushGPU();
        RHICmdList.BlockUntilGPUIdle();
        Ring->Poll(RHICmdList, true);
      }
      Ring->Slots.Empty();
      Ring->Size = Texture->GetSizeXY();
      Ring->Format = Texture->GetFormat();
      for (int32 Index = 0; Index < FMath::Clamp(SlotCount, 2, 3); ++Index)
      {
        Ring->Slots.Add(std::make_shared<FRHIGPUTextureReadback>(TEXT("CameraPersistentReadback")));
      }
    }
  }
  auto BackBufferReadback = Ring ? Ring->Acquire(RHICmdList) :
      std::make_shared<FRHIGPUTextureReadback>(TEXT("CameraBufferReadback"));
  double PhaseStart = Diagnostics ? FPlatformTime::Seconds() : 0.0;
  Timings.Create = PhaseStart - Timings.Started;
  FIntPoint BackBufferSize = Texture->GetSizeXY();
  EPixelFormat BackBufferPixelFormat = Texture->GetFormat();
  {
    TRACE_CPUPROFILER_EVENT_SCOPE_STR("EnqueueCopy");
    BackBufferReadback->EnqueueCopy(RHICmdList,
                                    Texture,
                                    FResolveRect(0, 0, BackBufferSize.X, BackBufferSize.Y));
  }
  if (Diagnostics)
  {
    const double Now = FPlatformTime::Seconds();
    Timings.Copy = Now - PhaseStart;
    PhaseStart = Now;
  }

  // workaround to force RHI with Vulkan to refresh the fences state in the middle of frame
  if (BlockingQuery)
  {
    FRenderQueryRHIRef Query;
    {
      TRACE_CPUPROFILER_EVENT_SCOPE_STR("Carla readback query create/end");
      Query = RHICreateRenderQuery(RQT_AbsoluteTime);
      RHICmdList.EndRenderQuery(Query);
    }
    if (Diagnostics)
    {
      const double Now = FPlatformTime::Seconds();
      Timings.Query = Now - PhaseStart;
      PhaseStart = Now;
    }
    {
      TRACE_CPUPROFILER_EVENT_SCOPE_STR("Carla readback RHI flush");
      RHICmdList.ImmediateFlush(EImmediateFlushType::FlushRHIThread);
    }
    if (Diagnostics)
    {
      const double Now = FPlatformTime::Seconds();
      Timings.Flush = Now - PhaseStart;
      PhaseStart = Now;
    }
    {
      TRACE_CPUPROFILER_EVENT_SCOPE_STR("Carla readback query wait");
      uint64 OldAbsTime = 0;
      RHICmdList.GetRenderQueryResult(Query, OldAbsTime, true);
    }
    if (Diagnostics)
    {
      Timings.QueryWait = FPlatformTime::Seconds() - PhaseStart;
    }
  }

  FPixelFormatInfo PixelFormat = GPixelFormats[BackBufferPixelFormat];
  uint32 ExpectedRowBytes = BackBufferSize.X * PixelFormat.BlockBytes;
  int32 Size = (BackBufferSize.Y * (PixelFormat.BlockBytes * BackBufferSize.X));

  // One common map/copy/unmap path. Persistent slots return to the ring only
  // after this closure and its mapped pointer are no longer in use.
  auto Complete = [Readback = BackBufferReadback, FuncForSending, Size, Offset, ExpectedRowBytes, Diagnostics, Timings, State]
      (FRHICommandListImmediate &InRHICmdList, double ReadyWait, double QueuedAt) mutable
  {
    if (State && State->Cancelled.load()) return;
    double Phase = Diagnostics ? FPlatformTime::Seconds() : 0.0;
    Timings.ReadyWait = ReadyWait;
    Timings.MapQueued = QueuedAt != 0.0 ? Phase - QueuedAt : 0.0;
    void *LockedData = Readback->Lock(Size);
    if (Diagnostics)
    {
      const double Now = FPlatformTime::Seconds();
      Timings.Map = Now - Phase;
      Phase = Now;
    }
    if (LockedData) FuncForSending(LockedData, Size, Offset, ExpectedRowBytes);
    else if (State) ++State->MapFailures;
    if (Diagnostics)
    {
      const double Now = FPlatformTime::Seconds();
      Timings.Payload = Now - Phase;
      Phase = Now;
    }
    Readback->Unlock();
    if (Diagnostics)
    {
      const double Now = FPlatformTime::Seconds();
      Timings.Unmap = Now - Phase;
      UE_LOG(LogCarla, Display, TEXT("CarlaCameraReadback %llu,%llu,%.9f,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d"),
          Timings.Sequence, Timings.Frame, Timings.Started, Timings.BlockingQuery,
          Timings.Create * 1000.0, Timings.Copy * 1000.0, Timings.Query * 1000.0,
          Timings.Flush * 1000.0, Timings.QueryWait * 1000.0, Timings.ReadyWait * 1000.0,
          Timings.MapQueued * 1000.0, Timings.Map * 1000.0, Timings.Payload * 1000.0,
          Timings.Unmap * 1000.0, (Now - Timings.Started) * 1000.0,
          FPlatformTime::ToMilliseconds(GGameThreadTime), FPlatformTime::ToMilliseconds(GRenderThreadTime),
          FPlatformTime::ToMilliseconds(GRHIThreadTime), FPlatformTime::ToMilliseconds(GGPUFrameTime), LockedData != nullptr);
    }
  };
  if (Ring)
  {
    const double QueuedAt = Diagnostics ? FPlatformTime::Seconds() : 0.0;
    Ring->Pending.push_back({BackBufferReadback, [Complete = std::move(Complete), QueuedAt](auto &Cmd) mutable
    {
      Complete(Cmd, 0.0, QueuedAt);
    }});
    ++Ring->Submitted;
    Ring->HighWater = FMath::Max(Ring->HighWater, Ring->Pending.size());
    if (SynchronousCapture)
    {
      // The client may wait for this image before issuing its next tick. Ensure
      // progress without needing another OnEndFrameRT poll.
      RHICmdList.SubmitCommandsAndFlushGPU();
      RHICmdList.BlockUntilGPUIdle();
      Ring->Poll(RHICmdList, true);
    }
    return;
  }

  AsyncTask(ENamedThreads::HighTaskPriority, [=, Readback=std::move(BackBufferReadback)]() mutable {
    const double WaitStart = Diagnostics ? FPlatformTime::Seconds() : 0.0;
    {
      TRACE_CPUPROFILER_EVENT_SCOPE_STR("Wait GPU transfer");
      while ((!State || !State->Cancelled.load()) && !Readback->IsReady())
      {
        std::this_thread::yield();
      }
    }
    const double QueuedAt = Diagnostics ? FPlatformTime::Seconds() : 0.0;
    const double ReadyWait = Diagnostics ? QueuedAt - WaitStart : 0.0;

    {
      TRACE_CPUPROFILER_EVENT_SCOPE_STR("Readback data");
      // The staging surfaces of the RHI are only accessible from the rendering
      // thread, so the readback is locked there. The Metal RHI of this engine
      // version does not implement a thread safe mapping of the staging surface.
      ENQUEUE_RENDER_COMMAND(FReadback_LockSurface)(
        [Readback = std::move(Readback), Complete = std::move(Complete), ReadyWait, QueuedAt](auto &InRHICmdList) mutable
        {
          Complete(InRHICmdList, ReadyWait, QueuedAt);
        });
    }
  });
}

void FPixelReader::CancelAndDrain(std::shared_ptr<FPixelReaderReadbackState> State)
{
  check(IsInGameThread());
  State->Cancelled.store(true);
  ENQUEUE_RENDER_COMMAND(FCancelCameraReadbacks)([State](auto &Cmd)
  {
    // Submit pending copies before releasing slots. No sensor actor is accessed.
    Cmd.SubmitCommandsAndFlushGPU();
    Cmd.BlockUntilGPUIdle();
    if (State->Ring)
    {
      auto Ring = State->Ring;
      FCoreDelegates::OnEndFrameRT.Remove(Ring->EndFrameHandle);
      Ring->Poll(Cmd, true);
      UE_LOG(LogCarla, Display, TEXT("CarlaCameraRing slots=%d submitted=%llu retired=%llu saturation=%llu highwater=%llu"),
          Ring->Slots.Num(), Ring->Submitted, Ring->Completed, Ring->Saturated, uint64(Ring->HighWater));
      State->Ring.reset();
    }
  });
  // A render flush alone cannot join workers which enqueue later. Cancellation
  // releases their readiness waits; keep flushing until every request is gone.
  do
  {
    FlushRenderingCommands();
    if (State->InFlight.load() != 0) FPlatformProcess::SleepNoStats(0.001f);
  } while (State->InFlight.load() != 0);
  UE_LOG(LogCarla, Display, TEXT("CarlaCameraCaptureStats requested=%llu send_attempts=%llu unsent=%llu map_failures=%llu in_flight=%llu"),
      uint64(State->Requested.load()), uint64(State->SendAttempts.load()),
      uint64(State->Requested.load() - State->SendAttempts.load()),
      uint64(State->MapFailures.load()), uint64(State->InFlight.load()));
}

bool FPixelReader::WritePixelsToArray(
    UTextureRenderTarget2D &RenderTarget,
    TArray<FColor> &BitMap)
{
  check(IsInGameThread());
  FTextureRenderTargetResource *RTResource =
      RenderTarget.GameThread_GetRenderTargetResource();
  if (RTResource == nullptr)
  {
    UE_LOG(LogCarla, Error, TEXT("FPixelReader: UTextureRenderTarget2D missing render target"));
    return false;
  }
  FReadSurfaceDataFlags ReadPixelFlags(RCM_UNorm);
  ReadPixelFlags.SetLinearToGamma(true);
  return RTResource->ReadPixels(BitMap, ReadPixelFlags);
}

TUniquePtr<TImagePixelData<FColor>> FPixelReader::DumpPixels(
    UTextureRenderTarget2D &RenderTarget)
{
  const FIntPoint DestSize(RenderTarget.GetSurfaceWidth(), RenderTarget.GetSurfaceHeight());
  TUniquePtr<TImagePixelData<FColor>> PixelData = MakeUnique<TImagePixelData<FColor>>(DestSize);
  TArray<FColor> Pixels(PixelData->Pixels.GetData(), PixelData->Pixels.Num());
  if (!WritePixelsToArray(RenderTarget, Pixels))
  {
    return nullptr;
  }
  PixelData->Pixels = Pixels;
  return PixelData;
}

TFuture<bool> FPixelReader::SavePixelsToDisk(
    UTextureRenderTarget2D &RenderTarget,
    const FString &FilePath)
{
  return SavePixelsToDisk(DumpPixels(RenderTarget), FilePath);
}

TFuture<bool> FPixelReader::SavePixelsToDisk(
    TUniquePtr<TImagePixelData<FColor>> PixelData,
    const FString &FilePath)
{
  TUniquePtr<FImageWriteTask> ImageTask = MakeUnique<FImageWriteTask>();
  ImageTask->PixelData = MoveTemp(PixelData);
  ImageTask->Filename = FilePath;
  ImageTask->Format = EImageFormat::PNG;
  ImageTask->CompressionQuality = (int32) EImageCompressionQuality::Default;
  ImageTask->bOverwriteFile = true;
  ImageTask->PixelPreProcessors.Add(TAsyncAlphaWrite<FColor>(255));

  FHighResScreenshotConfig &HighResScreenshotConfig = GetHighResScreenshotConfig();
  return HighResScreenshotConfig.ImageWriteQueue->Enqueue(MoveTemp(ImageTask));
}
