defmodule Postgrex.SimpleConnection do
  @moduledoc false

  use Connection

  require Logger

  alias Postgrex.Protocol

  @doc false
  defstruct idle_interval: 5000,
            protocol: nil,
            auto_reconnect: false,
            reconnect_backoff: 500,
            state: nil

  ## PUBLIC API ##

  @type query :: iodata
  @type state :: term

  @doc """
  Callback for process initialization.

  This is called once and before the Postgrex connection is established.
  """
  @callback init(term) :: {:ok, state}

  @doc """
  Callback for processing or relaying pubsub notifications.
  """
  @callback notify(binary, binary, state) :: :ok

  @doc """
  Invoked after connecting.

  This may be called multiple times if `:auto_reconnect` is true.
  """
  @callback handle_connect(state) :: {:noreply, state} | {:query, query, state}

  @doc """
  Invoked after disconnection, regardless of `:auto_reconnect`.
  """
  @callback handle_disconnect(state) :: {:noreply, state}

  @doc """
  Callback for `call/3`.

  Replies must be sent with `reply/2`.
  """
  @callback handle_call(term, GenServer.from(), state) ::
              {:noreply, state} | {:query, query, state}

  @doc """
  Callback for `Kernel.send/2`.
  """
  @callback handle_info(term, state) :: {:noreply, state} | {:query, query, state}

  @doc """
  Callback for processing or relaying query results.
  """
  @callback handle_result(Postgrex.Result.t() | Postgrex.Error.t(), state) :: {:noreply, state}

  @optional_callbacks handle_call: 3,
                      handle_connect: 1,
                      handle_disconnect: 1,
                      handle_info: 2,
                      handle_result: 2

  @doc """
  Replies to the given client.

  Wrapper for `GenServer.reply/2`.
  """
  defdelegate reply(client, reply), to: GenServer

  @doc """
  Calls the given server.

  Wrapper for `GenServer.call/3`.
  """
  def call(server, message, timeout \\ 5000) do
    with {__MODULE__, reason} <- GenServer.call(server, message, timeout) do
      exit({reason, {__MODULE__, :call, [server, message, timeout]}})
    end
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, opts}}
  end

  @doc """
  Start the connection process and connect to Postgres.

  The options that this function accepts are the same as those accepted by
  `Postgrex.start_link/1`, as well as the extra options `:sync_connect`,
  `:auto_reconnect`, `:reconnect_backoff`, and `:configure`.

  ## Options

    * `:auto_reconnect` - automatically attempt to reconnect to the database
      in event of a disconnection. See the
      [note about async connect and auto-reconnects](#module-async-connect-and-auto-reconnects)
      above. Defaults to `false`, which means the process terminates.

    * `:configure` - A function to run before every connect attempt to dynamically
      configure the options as a `{module, function, args}`, where the current
      options will prepended to `args`. Defaults to `nil`.

    * `:idle_interval` - while also accepted on `Postgrex.start_link/1`, it has
      a default of `5000ms` in `Postgrex.SimpleConnection` (instead of 1000ms).

    * `:reconnect_backoff` - time (in ms) between reconnection attempts when
      `auto_reconnect` is enabled. Defaults to `500`.

    * `:sync_connect` - controls if the connection should be established on boot
      or asynchronously right after boot. Defaults to `true`.
  """
  @spec start_link(module, term, Keyword.t()) :: {:ok, pid} | {:error, Postgrex.Error.t() | term}
  def start_link(module, args, opts) do
    {server_opts, opts} = Keyword.split(opts, [:name])
    opts = Keyword.put_new(opts, :sync_connect, true)
    connection_opts = Postgrex.Utils.default_opts(opts)
    Connection.start_link(__MODULE__, {module, args, connection_opts}, server_opts)
  end

  ## CALLBACKS ##

  @doc false
  def init({mod, args, opts}) do
    case mod.init(args) do
      {:ok, mod_state} ->
        idle_timeout = opts[:idle_timeout]

        if idle_timeout do
          Logger.warn(
            ":idle_timeout in Postgrex.SimpleConnection is deprecated, " <>
              "please use :idle_interval instead"
          )
        end

        {idle_interval, opts} = Keyword.pop(opts, :idle_interval, idle_timeout || 5000)
        {auto_reconnect, opts} = Keyword.pop(opts, :auto_reconnect, false)
        {reconnect_backoff, opts} = Keyword.pop(opts, :reconnect_backoff, 500)

        state = %__MODULE__{
          idle_interval: idle_interval,
          auto_reconnect: auto_reconnect,
          reconnect_backoff: reconnect_backoff,
          state: {mod, mod_state}
        }

        put_opts(mod, opts)

        if opts[:sync_connect] do
          case connect(:init, state) do
            {:ok, _} = ok -> ok
            {:backoff, _, _} = backoff -> backoff
            {:stop, reason, _} -> {:stop, reason}
          end
        else
          {:connect, :init, state}
        end
    end
  end

  @doc false
  def connect(_, %{state: {mod, mod_state}} = state) do
    opts =
      case Keyword.get(opts(mod), :configure) do
        {module, fun, args} -> apply(module, fun, [opts(mod) | args])
        fun when is_function(fun, 1) -> fun.(opts(mod))
        nil -> opts(mod)
      end

    case Protocol.connect(opts) do
      {:ok, protocol} ->
        state = %{state | protocol: protocol}

        with {:noreply, state, _} <- maybe_handle(mod, :handle_connect, [mod_state], state) do
          {:ok, state}
        end

      {:error, reason} ->
        if state.auto_reconnect do
          {:backoff, state.reconnect_backoff, state}
        else
          {:stop, reason, state}
        end
    end
  end

  @doc false
  def handle_call(msg, from, %{state: {mod, mod_state}} = state) do
    handle(mod, :handle_call, [msg, from, mod_state], from, state)
  end

  @doc false
  def handle_info(:timeout, %{protocol: protocol} = state) do
    case Protocol.ping(protocol) do
      {:ok, protocol} ->
        {:noreply, %{state | protocol: protocol}, state.idle_interval}

      {error, reason, protocol} ->
        reconnect_or_stop(error, reason, protocol, state)
    end
  end

  def handle_info(msg, %{protocol: protocol, state: {mod, mod_state}} = state) do
    opts = [notify: &mod.notify(&1, &2, mod_state)]

    case Protocol.handle_info(msg, opts, protocol) do
      {:ok, protocol} ->
        {:noreply, %{state | protocol: protocol}, state.idle_interval}

      {:unknown, protocol} ->
        maybe_handle(mod, :handle_info, [msg, mod_state], %{state | protocol: protocol})

      {error, reason, protocol} ->
        reconnect_or_stop(error, reason, protocol, state)
    end
  end

  def handle_info(msg, %{state: {mod, mod_state}} = state) do
    maybe_handle(mod, :handle_info, [msg, mod_state], state)
  end

  defp maybe_handle(mod, fun, args, state) do
    if function_exported?(mod, fun, length(args)) do
      handle(mod, fun, args, nil, state)
    else
      {:noreply, state, state.idle_interval}
    end
  end

  defp handle(mod, fun, args, from, state) do
    case apply(mod, fun, args) do
      {:noreply, mod_state} ->
        {:noreply, %{state | state: {mod, mod_state}}, state.idle_interval}

      {:query, query, mod_state} ->
        opts = [notify: &mod.notify(&1, &2, mod_state)]

        state = %{state | state: {mod, mod_state}}

        with {:ok, result, protocol} <- Protocol.handle_simple(query, opts, state.protocol),
             {:ok, protocol} <- Protocol.checkin(protocol) do
          state = %{state | protocol: protocol}

          handle(mod, :handle_result, [result, mod_state], from, state)
        else
          {:error, %Postgrex.Error{} = error, protocol} ->
            handle(mod, :handle_result, [error, mod_state], from, %{state | protocol: protocol})

          {:disconnect, reason, protocol} ->
            reconnect_or_stop(:disconnect, reason, protocol, state)
        end
    end
  end

  defp reconnect_or_stop(error, reason, protocol, %{state: {mod, mod_state}} = state)
       when error in [:error, :disconnect] do
    {:noreply, state, _} = maybe_handle(mod, :handle_disconnect, [mod_state], state)

    if state.auto_reconnect do
      {:connect, :reconnect, state}
    else
      {:stop, reason, %{state | protocol: protocol}}
    end
  end

  defp opts(mod), do: Process.get(mod)

  defp put_opts(mod, opts), do: Process.put(mod, opts)
end
