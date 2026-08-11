defmodule Revela.Capture.HostViewerTest do
  use Revela.DataCase, async: false

  alias Revela.Capture

  describe "broadcast_host_viewer" do
    test "nao retransmite quando photo_id/follow/open nao mudam" do
      Capture.reset_host_viewer_state()
      Capture.subscribe_host_viewer()

      Capture.broadcast_host_viewer(%{photo_id: 7, follow: false, open: true})
      assert_receive {:host_viewer, %{photo_id: 7, follow: false, open: true}}

      Capture.broadcast_host_viewer(%{photo_id: 7, follow: false, open: true})
      refute_receive {:host_viewer, _}, 50

      Capture.broadcast_host_viewer(%{photo_id: 8, follow: false, open: true})
      assert_receive {:host_viewer, %{photo_id: 8, follow: false, open: true}}
    end
  end

  describe "host_viewer_mirror_state" do
    test "sem Host registrado, ignora estado bruto retido" do
      Capture.reset_host_viewer_state()
      Capture.broadcast_host_viewer(%{photo_id: 9, follow: false, open: true})

      refute Capture.host_present?()
      assert Capture.host_viewer_state() == %{photo_id: 9, follow: false, open: true}
      assert Capture.host_viewer_mirror_state() == %{photo_id: nil, follow: true, open: false}
    end

    test "com Host registrado, espelha o estado bruto" do
      Capture.reset_host_viewer_state()
      Capture.broadcast_host_viewer(%{photo_id: 11, follow: false, open: true})

      parent = self()

      {:ok, host_pid} =
        Task.start(fn ->
          Capture.track_host()
          send(parent, :tracked)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :tracked
      assert Capture.host_present?()
      assert Capture.host_viewer_mirror_state() == %{photo_id: 11, follow: false, open: true}

      send(host_pid, :stop)
      ref = Process.monitor(host_pid)
      assert_receive {:DOWN, ^ref, :process, ^host_pid, _}
      # Registry's own DOWN-driven cleanup of the entry races the test
      # process; :sys.get_state on the registry name doesn't sync on that
      # internal listener, so poll briefly instead of asserting immediately.
      wait_until(fn -> not Capture.host_present?() end)
    end
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end
end
