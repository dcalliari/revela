defmodule Revela.Delivery.GoogleDrive do
  @moduledoc """
  Stub: pasta no Google Drive (backup/arquivo). Distinto de Fotos (entrega visual).
  Sem credenciais retorna `{:error, :not_configured}`.
  """

  def create(_editorial_id, _photo_ids, _label \\ nil), do: {:error, :not_configured}
end
