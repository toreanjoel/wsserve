defmodule Wsserve.Servers.Subserver do
  @moduledoc """
    This is the server for each of the socker processes that will manage state.
    This will manage room states (later agents per room) but general channel data
    clients interact against.

    Server manager is repsonsibile for asking a dynamic supervisor to init with relevant config
  """
  use GenServer, restart: :temporary
  require Logger

  def start_link(args \\ %{}) do
    # Generate a default UUID
    default_uuid = UUID.uuid4()

    # Extract the id from custom_state if it exists and is not empty
    id =
      args
      |> Map.get(:custom_state, %{})
      |> Map.get(:config, %{})
      |> Map.get(:id, default_uuid)

    Logger.info("starting with id: #{id}")

    GenServer.start_link(
      __MODULE__,
      Map.merge(args, %{id: id}),
      name: String.to_atom(Atom.to_string(__MODULE__) <> ":" <> id)
    )
  end

  def init(args) do
    Logger.info("args init")
    Logger.info(inspect(args))

    config = %Wsserve.Servers.Subserver.Config{
      pid: self(),
      manager_pid: args.manager_pid,
      id: Map.get(args, :id)
    }

    # we set the deafault state of allowing a lobby for all servers
    base_state = %{
      config: config,
      channel_states: %{
        "lobby" => %Wsserve.Servers.Subserver.Structs{type: :default, state: %{}}
      }
    }

    state =
      case init_state = args.custom_state do
        nil ->
          base_state

        _ ->
          Map.merge(base_state, Map.delete(init_state, :config))
      end

    # tell parent that we are ready with config details
    send(args.manager_pid, {:server_config, state.config})
    {:ok, state}
  end

  # Get the current config details stored
  def handle_call(:get_config, _from, state) do
    if data = Map.get(state, :config, false) do
      {:reply, {:ok, data}, state}
    else
      {:reply, {:error, "No config found. Make sure it exists"}, state}
    end
  end

  # Returns all the room states that exist currently
  def handle_call(:get_channels, _from, state) do
    {:reply, Map.keys(state.channel_states), state}
  end

  # Get the state by the channel name currently stored in the server
  def handle_call({:get_channel, channel}, _from, state) do
    if data = Map.get(state.channel_states, channel, false) do
      {:reply, {:ok, data}, state}
    else
      {:reply, {:error, "No channel found, create or make sure it exists."}, state}
    end
  end

  # Sync: Update the state of the specific channel - will merge to the data currenly existing in memory
  def handle_call({:update_channel, channel, data}, _from, state) do
    curr_channel = Map.get(state.channel_states, channel, false)

    if curr_channel do
      type = curr_channel.type
      updated_state = channel_state_update(channel, data, state, type)
      # TODO: consider sending through errors if types if payload is not correct
      {:reply, {:ok, updated_state}, updated_state}
    else
      Logger.error("Unable to find channel to update")
      {:reply, {:ok, state}, state}
    end
  end

  # Global room or channel state that will be initalized with properties
  def handle_call({:create_channel, channel_name, type, init_payload}, _from, state)
      when type == :shared_state do
    # Get the init payload fallback to empty - ideally the user sets relevant keys
    init_payload = init_payload || %{}

    # TODO: We need to consider making sure if keys are added, the key needs a set mode
    # this mode is then used to determine how we update that key.
    # For now we always replace the global state.
    # NOTE: We rely on the gen server to manage the order of the updates

    channel =
      Map.put(
        state.channel_states,
        channel_name,
        %Wsserve.Servers.Subserver.Structs{type: type, state: init_payload}
      )

    new_state = Map.put(state, :channel_states, channel)
    {:reply, {:ok, "Channel #{channel_name} created with type #{type}"}, new_state}
  end

  # create a channel by type either collab or accumulative
  def handle_call({:create_channel, channel_name, type}, _from, state) do
    channel =
      Map.put(
        state.channel_states,
        # We make sure we dont have spaces
        # TODO: replace or dont allow special characters
        channel_name |> String.trim() |> String.replace(" ", "_"),
        %Wsserve.Servers.Subserver.Structs{type: type, state: %{}}
      )

    new_state = Map.put(state, :channel_states, channel)
    {:reply, {:ok, "Channel #{channel_name} created with type #{type}"}, new_state}
  end

  # here we listen for the requests to send configs to process to manage
  def handle_info({:request_config, caller_pid}, state) do
    send(caller_pid, {:server_config, state.config})
    {:noreply, state}
  end

  # Here we update channel data to the state - accumualtive or collaborative
  # TODO: break this down so that its less
  defp channel_state_update(channel, data, %{channel_states: channel_states} = state, type)
       when type in [:accumulative_state, :collaborative_state, :shared_state] do
    curr_channel = Map.get(channel_states, channel, %{})

    updated_details =
      case type do
        :accumulative_state ->
          payload = Map.new() |> Map.put(DateTime.utc_now() |> DateTime.to_unix(), data)
          Map.merge(curr_channel.state, payload)

        :collaborative_state ->
          # Assuming data is a map with user ID as key and payload as value
          payload = Map.new() |> Map.put(data.user.id, data)
          Map.merge(curr_channel.state, payload)

        :shared_state ->
          # TODO: Accumulate data later
          # TODO: We need to make sure the types match, if we have string init values, update needs to match
          room_state = curr_channel.state
          # Here we take the passed data and try add
          updated_init =
            Enum.reduce(Map.keys(data.payload), room_state, fn curr_data_key, curr_room_state ->
              if Map.has_key?(curr_room_state, curr_data_key) do
                Map.put(curr_room_state, curr_data_key, Map.get(data.payload, curr_data_key))
              else
                curr_room_state
              end
            end)

          Map.merge(room_state, updated_init)

        _ ->
          Logger.error("Unknown channel type: #{inspect(type)}")
          curr_channel.state
      end

    updated_channel_states =
      Map.put(channel_states, channel, %{curr_channel | state: updated_details})

    Map.put(state, :channel_states, updated_channel_states)
  end

  # dispatch response to user
  # TODO: we need to send or broadcast to the user socket, we dont send back to the user
end
