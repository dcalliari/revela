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
end
