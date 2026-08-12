defmodule RevelaWeb.RawDownloadControllerTest do
  use RevelaWeb.ConnCase, async: false

  alias Revela.{Capture, Repo}
  alias Revela.Delivery.RawDownload
  alias RevelaWeb.RawDownloadController

  test "baixa zip quando raw_path existe", %{conn: conn} do
    {:ok, editorial} = Capture.start_editorial("Raw", "/tmp/raw-#{System.unique_integer()}")
    dir = Path.join(System.tmp_dir!(), "revela-dl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    raw = Path.join(dir, "IMG.CR2")
    File.write!(raw, "RAWDATA")

    {:ok, photo} =
      Capture.create_photo(%{web_path: "/uploads/r.jpg", raw_path: raw})

    token = RawDownloadController.create_token(editorial.id, [photo.id])
    conn = get(conn, ~p"/raws/#{token}")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"
    assert conn.resp_body != ""
  end

  test "422 quando nenhum RAW disponivel", %{conn: conn} do
    {:ok, editorial} = Capture.start_editorial("SemRaw", "/tmp/sem-#{System.unique_integer()}")
    {:ok, photo} = Capture.create_photo(%{web_path: "/uploads/s.jpg"})

    token = RawDownloadController.create_token(editorial.id, [photo.id])
    conn = get(conn, ~p"/raws/#{token}")

    assert conn.status == 422
    assert conn.resp_body =~ "raw_path"
  end

  test "link expirado nao entrega o arquivo", %{conn: conn} do
    {:ok, editorial} =
      Capture.start_editorial("Expirado", "/tmp/expirado-#{System.unique_integer()}")

    dir = Path.join(System.tmp_dir!(), "revela-exp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    raw = Path.join(dir, "IMG.CR2")
    File.write!(raw, "RAWDATA")
    {:ok, photo} = Capture.create_photo(%{web_path: "/uploads/e.jpg", raw_path: raw})
    {:ok, token} = RawDownloadController.create_token(editorial.id, [photo.id])
    Repo.update_all(RawDownload, set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

    conn = get(conn, ~p"/raws/#{token}")
    assert conn.status == 403
    refute conn.resp_body =~ "RAWDATA"
  end

  test "403 com token invalido", %{conn: conn} do
    conn = get(conn, ~p"/raws/invalid-token")
    assert conn.status == 403
  end
end
