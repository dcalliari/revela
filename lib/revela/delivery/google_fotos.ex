defmodule Revela.Delivery.GoogleFotos do
  @moduledoc """
  Stub: album no Google Fotos para a marca. Proximo passo apos o URL local.
  Requer OAuth — sem credenciais retorna `{:error, :not_configured}`.
  """

  def create(_editorial_id, _photo_ids, _label \\ nil), do: {:error, :not_configured}
end
