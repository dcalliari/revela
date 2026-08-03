defmodule RevelaWeb.Presence do
  use Phoenix.Presence,
    otp_app: :revela,
    pubsub_server: Revela.PubSub

  @topic "reviewers"

  def topic, do: @topic

  def track_reviewer(pid, reviewer_id, reviewer_name) do
    track(pid, @topic, reviewer_id, %{
      name: reviewer_name,
      online_at: System.system_time(:second)
    })
  end

  def list_reviewers do
    list(@topic)
    |> Enum.map(fn {id, %{metas: [meta | _]}} -> Map.put(meta, :id, id) end)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Revela.PubSub, @topic)
  end
end
