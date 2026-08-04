using Microsoft.Graphics.Canvas;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

namespace Dayflow.Windows.Capture;

/// <summary>
/// Owns the Windows.Graphics.Capture Direct3D11 frame pool. A frame is used
/// only long enough to emit a derived metadata sample and is disposed before
/// control returns to the capture callback.
/// </summary>
public sealed class WindowsGraphicsCaptureFramePipeline : IWindowsFramePipeline, IDisposable
{
    private const int BufferCount = 2;

    private readonly IDirect3DDevice _device;
    private Direct3D11CaptureFramePool? _framePool;
    private GraphicsCaptureSession? _session;
    private Action<WindowsCaptureSample>? _onFrame;
    private (int Width, int Height) _frameSize;
    private readonly object _gate = new();

    public WindowsGraphicsCaptureFramePipeline(IDirect3DDevice device)
    {
        _device = device;
    }

    public Task StartAsync(GraphicsCaptureItem item, Action<WindowsCaptureSample> onFrame)
    {
        lock (_gate)
        {
            StopLocked();
            _onFrame = onFrame;
            _frameSize = (item.Size.Width, item.Size.Height);

            _framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                _device,
                DirectXPixelFormat.B8G8R8A8UIntNormalized,
                BufferCount,
                item.Size);
            _framePool.FrameArrived += FramePool_FrameArrived;

            _session = _framePool.CreateCaptureSession(item);
            // The Windows API keeps its visible capture indication enabled by
            // default. Dayflow does not opt into the borderless capture mode.
            _session.StartCapture();
        }
        return Task.CompletedTask;
    }

    public void Stop()
    {
        lock (_gate)
        {
            StopLocked();
        }
    }

    private void StopLocked()
    {
        if (_session is not null)
        {
            _session.Dispose();
            _session = null;
        }

        if (_framePool is not null)
        {
            _framePool.FrameArrived -= FramePool_FrameArrived;
            _framePool.Dispose();
            _framePool = null;
        }

        _onFrame = null;
        _frameSize = default;
    }

    public void Dispose() => Stop();

    private void FramePool_FrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        WindowsCaptureSample? sample = null;
        Action<WindowsCaptureSample>? callback = null;
        (int Width, int Height) contentSize = default;

        // The callback is free-threaded. Snapshot and release the GPU frame
        // under the pipeline lock, then invoke the adapter outside the lock so
        // a privacy decision can stop the pipeline without deadlocking the
        // frame pool.
        lock (_gate)
        {
            if (!ReferenceEquals(_framePool, sender))
            {
                return;
            }

            using (var frame = sender.TryGetNextFrame())
            {
                if (frame is null)
                {
                    return;
                }

                contentSize = (frame.ContentSize.Width, frame.ContentSize.Height);
                callback = _onFrame;
                sample = new WindowsCaptureSample(
                    DateTimeOffset.UtcNow,
                    contentSize.Width,
                    contentSize.Height);
            }
        }

        if (sample is not null)
        {
            callback?.Invoke(sample);
        }

        // A selected window can be resized or moved across monitors while a
        // session is running. The Windows API requires the frame pool to be
        // recreated for the new buffer size; otherwise frames may be dropped
        // or the pipeline can stop after the first resize.
        lock (_gate)
        {
            if (contentSize.Width <= 0
                || contentSize.Height <= 0
                || contentSize == _frameSize
                || !ReferenceEquals(_framePool, sender)
                || _session is null)
            {
                return;
            }

            try
            {
                sender.Recreate(
                    _device,
                    DirectXPixelFormat.B8G8R8A8UIntNormalized,
                    BufferCount,
                    new global::Windows.Graphics.SizeInt32
                    {
                        Width = contentSize.Width,
                        Height = contentSize.Height,
                    });
                _frameSize = contentSize;
            }
            catch (ObjectDisposedException)
            {
                // Stop/close can win the race after the frame was released.
                // The next explicit picker choice creates a fresh pipeline.
            }
        }
    }
}

/// <summary>
/// Creates the Win2D-backed Direct3D device accepted by
/// Direct3D11CaptureFramePool. The device is owned by the window lifetime.
/// </summary>
public sealed class WindowsCaptureDevice : IDisposable
{
    private readonly CanvasDevice _canvasDevice = CanvasDevice.GetSharedDevice();

    public IDirect3DDevice Direct3DDevice => _canvasDevice;

    public void Dispose() => _canvasDevice.Dispose();
}
