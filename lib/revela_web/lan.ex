defmodule RevelaWeb.Lan do
  @moduledoc """
  Endereço IPv4 acessível pelos celulares na LAN.

  Pode ser fixado via `TETHER_LAN_IP`; senão escolhe entre as interfaces
  ignorando loopback, link-local, CGNAT/Tailscale, docker/bridges e VPNs,
  preferindo 192.168/10/172.
  """

  def absolute_url(path) when is_binary(path) do
    "http://#{lan_ip()}:#{http_port()}#{path}"
  end

  def base_url do
    "http://#{lan_ip()}:#{http_port()}/"
  end

  def http_port do
    :revela
    |> Application.get_env(RevelaWeb.Endpoint, [])
    |> get_in([:http, :port]) || 4000
  end

  def lan_ip do
    System.get_env("TETHER_LAN_IP") || detect_lan_ip() || "localhost"
  end

  defp detect_lan_ip do
    {:ok, ifs} = :inet.getifaddrs()

    ifs
    |> Enum.reject(fn {name, _opts} -> skip_iface?(to_string(name)) end)
    |> Enum.flat_map(fn {_name, opts} -> Keyword.get_values(opts, :addr) end)
    |> Enum.filter(&usable_ipv4?/1)
    |> Enum.sort_by(&ipv4_rank/1)
    |> List.first()
    |> case do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end
  end

  defp skip_iface?(name) do
    String.starts_with?(name, ~w(lo docker br- veth virbr tailscale tun wg zt))
  end

  defp usable_ipv4?({127, _, _, _}), do: false
  defp usable_ipv4?({169, 254, _, _}), do: false
  # 100.64.0.0/10 = CGNAT (Tailscale e afins)
  defp usable_ipv4?({100, b, _, _}) when b in 64..127, do: false
  defp usable_ipv4?({a, _, _, _}) when a in 1..223, do: true
  defp usable_ipv4?(_), do: false

  defp ipv4_rank({192, 168, _, _}), do: 0
  defp ipv4_rank({10, _, _, _}), do: 1
  defp ipv4_rank({172, b, _, _}) when b in 16..31, do: 2
  defp ipv4_rank(_), do: 3
end
