defmodule Revela.Capture.CameraServerTest do
  use ExUnit.Case, async: false

  alias Revela.Capture
  alias Revela.Capture.CameraServer

  test "nao arma a captura quando nenhuma camera foi detectada" do
    detector_state = start_supervised!({Agent, fn -> false end})
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000
      })

    wait_for_presence_check(server)

    assert CameraServer.start_capture(server) == %{
             camera_present: false,
             editorial: nil,
             message: nil,
             status: :idle
           }

    Agent.update(detector_state, fn _present? -> true end)
    send(server, :poll_presence)

    assert_receive {:capture_status, %{camera_present: true, status: :idle}}
    assert CameraServer.status(server).status == :idle
  end

  defp wait_for_presence_check(server) do
    case :sys.get_state(server).presence_check_ref do
      nil -> :ok
      _check_ref -> wait_for_presence_check(server)
    end
  end

  defp temporary_editorials_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "revela-camera-server-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
