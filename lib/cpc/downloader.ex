defmodule Cpc.Downloader do
  require Logger
  use GenServer

  # TODO we need to take care that, when the client downloads a partial file, we will also only
  # download a partial file (i.e., do not serve a partial file when a client subsequently requests
    # the full file!).

  def start_link([sock], []) do
    GenServer.start_link(__MODULE__, {sock, :recv_header, %{uri: nil, range_start: nil}})
  end

  # returns {:exists, filename} if it exists, else {:not_found, filename}
  # when {:not_found, filename} is returned, filename is the file where the file is meant to be
  # stored in before symlinking.
  defp get_filename(uri) do
    cache_dir = Application.get_env(:cpc, :cache_directory)
    http_source = get_url()
    filename = Path.join(cache_dir, uri)
    dirname = Path.dirname(filename)
    basename = Path.basename(filename)
    file_exists = Enum.member?(File.ls!(dirname), basename)
    is_database = String.ends_with?(basename, ".db")
    case {is_database, file_exists} do
      {true, _} ->
        {:database, Path.join(http_source, uri)}
      {false, false} ->
        {:not_found, Path.join([dirname, "downloads", basename])}
      {false, true} ->
        {:file, filename}
    end
  end

  def get_url() do
    Application.get_env(:cpc, :mirror) |> String.replace_suffix("/", "")
  end

  defp header(content_length, full_content_length, range_start \\ nil) do
    content_range_line = case range_start do
      nil ->
        ""
      rs ->
        range_end = full_content_length - 1
        "Content-Range: #{rs}-#{range_end}/#{full_content_length}\r\n"
    end
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 200 OK\r\n" <>
    "Server: http-relay\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Type: application/octet-stream\r\n" <>
    "Content-Length: #{content_length}\r\n" <>
    content_range_line <>
    "\r\n"
  end

  defp header_301(location) do
    date = to_string(:httpd_util.rfc1123_date)
    "HTTP/1.1 301 Moved Permanently\r\n" <>
    "Server: http-relay\r\n" <>
    "Date: #{date}\r\n" <>
    "Content-Type: text/html\r\n" <>
    "Content-Length: 0\r\n" <>
    "Location: #{location}\r\n\r\n"
  end

  defp setup_port(filename) do
    cmd = "/usr/bin/inotifywait"
    args = ["-q", "--format", "%e", "--monitor", "-e", "modify", filename]
    Logger.warn "attempt to start port"
    _ = Port.open({:spawn_executable, cmd}, [{:args, args}, :stream, :binary, :exit_status,
                                           :hide, :use_stdio, :stderr_to_stdout])
    Logger.warn "port started"
  end

  def handle_info({:http, _, {:http_request, :GET, {:abs_path, path}, _}}, {sock, :recv_header, hs}) do
    uri = case path do
      "/" <> rest -> URI.decode(rest)
    end
    Logger.warn "uri is: #{uri}"
    {:noreply, {sock, :recv_header, %{hs | uri: uri}}}
  end

  def handle_info({:http, _, {:http_header, _, :Range, _, range}}, {sock, :recv_header, hs}) do
    Logger.warn "attempt to parse range header"
    range_start = case range do
      "bytes=" <> rest ->
        {start, "-"} = Integer.parse(rest)
        start
    end
    Logger.warn "range starts at #{range_start}"
    {:noreply, {sock, :recv_header, %{hs | range_start: range_start}}}
  end

  def handle_info({:http, _, :http_eoh}, {sock, :recv_header, hs}) do
    Logger.info "received header entirely: #{inspect hs}"
    case get_filename(hs.uri) do
      {:database, db_url} ->
        Logger.debug "Serve database file via http redirect"
        :ok = :gen_tcp.send(sock, header_301(db_url))
        :ok = :gen_tcp.close(sock)
        {:noreply, :sock_closed}
      {:file, filename} ->
        _ = Logger.info "Serve file #{filename} from cache."
        content_length = File.stat!(filename).size
        reply_header = header(content_length, content_length, hs.range_start)
        :ok = :gen_tcp.send(sock, reply_header)
        case hs.range_start do
          nil ->
            {:ok, ^content_length} = :file.sendfile(filename, sock)
          rs ->
            Logger.warn "send partial file, from #{rs} until end."
            f = File.open!(filename, [:read, :raw])
            {:ok, _} = :file.sendfile(f, sock, hs.range_start, content_length - rs, [])
            File.close(f)
        end
        _ = Logger.debug "Download from cache complete."
        :ok = :gen_tcp.close(sock)
        {:stop, :normal, nil}
      {:not_found, filename} ->
        send Cpc.Serializer, {self(), :state?, filename}
        Logger.debug "send :state? from #{inspect self()}"
        receive do
          {:downloading, content_length} ->
            setup_port(filename)
            Logger.info "File #{filename} is already being downloaded, initiate download from " <>
                        "growing file."
            reply_header = header(content_length, hs.range_start)
            :ok = :gen_tcp.send(sock, reply_header)
            file = File.open!(filename, [:read, :raw])
            {:noreply, {:tail, sock, {file, filename}, content_length, 0}}
          :unknown ->
            _ = Logger.info "serve file #{filename} via HTTP."
            url = Path.join(get_url(), hs.uri)
            _ = Logger.warn "URL is #{inspect url}"
            headers = case hs.range_start do
              nil ->
                []
              rs -> [{"Range", "bytes=#{rs}-"}]
            end
            {:ok, _} = :hackney.request(:get, url, headers, "", [:async])
            {content_length, full_content_length} = content_length_from_mailbox()
            _ = Logger.info "content length: #{content_length}"
            reply_header = header(content_length, full_content_length, hs.range_start)
            Logger.warn "send header: #{inspect reply_header}"
            send Cpc.Serializer, {self(), :content_length, {filename, content_length}}
            :ok = :gen_tcp.send(sock, reply_header)
            _ = Logger.info "sent header: #{reply_header}"
            file = File.open!(filename, [:write])
            {:noreply, {:download, sock, {file, filename}}}
        end
    end
  end

  def handle_info({:hackney_response, _, :done}, {:download, sock, {f, n}}) do
    :ok = File.close(f)
    basename = Path.basename(n)
    dirname = Path.dirname(n)
    prev_dir = System.cwd
    download_dir_basename = n |> Path.dirname |> Path.basename
    :ok = :file.set_cwd(Path.join(dirname, ".."))
    :ok = File.ln_s(Path.join(download_dir_basename, basename), basename)
    :ok = :file.set_cwd(prev_dir)
    _ = Logger.info "Closing file and socket."
    :ok = :gen_tcp.close(sock)
    :ok = GenServer.cast(Cpc.Serializer, {:download_completed, n})
    {:noreply, :sock_closed}
  end

  def handle_info({:hackney_response, _, bin}, state = {:download, sock, {f, n}}) do
    :ok = IO.binwrite(f, bin)
    case :gen_tcp.send(sock, bin) do
      :ok ->
        {:noreply, state}
      {:error, :closed} ->
        Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
        :ok = GenServer.cast(Cpc.Serializer, {:download_completed, n})
        {:noreply, :sock_closed}
    end
  end

  def handle_info({:tcp_closed, _}, {:download, _, {_,n}}) do
    Logger.info "Connection closed by client during data transfer. File #{n} is incomplete."
    :ok = GenServer.cast(Cpc.Serializer, {:download_completed, n})
    {:stop, :normal, nil}
  end

  def handle_info({port, {:data, "MODIFY\n" <> _}, },
                  state = {:tail, sock, {f, n}, content_length, size}) do
    new_size = File.stat!(n).size
    case new_size do
      ^content_length ->
        Logger.debug "Download from growing file complete."
        {:ok, _} = :file.sendfile(f, sock, size, new_size - size, [])
        Port.close(port)
        :ok = File.close(f)
        :ok = :gen_tcp.close(sock)
        {:noreply, :sock_closed}
      ^size ->
        # received MODIFY although size is unchanged -- probably because something was written to
        # the file after the previous MODIFY event and before we have called File.stat.
        {:noreply, state}
      _ ->
        true = new_size < content_length
        {:ok, _} = :file.sendfile(f, sock, size, new_size - size, [])
        {:noreply, {:tail, sock, {f, n}, content_length, new_size}}
    end
  end


  def handle_info({:http, _sock, http_packet}, state) do
    Logger.warn "recvd #{inspect http_packet}"
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _}, :sock_closed) do
    Logger.info "connection closed."
    {:stop, :normal, nil}
  end

  defp content_length_from_mailbox() do
    partial_or_complete = receive do
      {:hackney_response, _, {:status, 200, _}} ->
        Logger.debug "Received 200, download entire file via HTTP."
        :complete
      {:hackney_response, _, {:status, 206, _}} ->
        Logger.info "Received 206, download partial file via HTTP."
        :partial
      {:hackney_response, _, {:status, num, msg}} ->
        raise "Expected HTTP response 200, got instead: #{num} (#{msg})"
    after 1000 ->
        raise "Timeout while waiting for response to GET request."
    end
    header = receive do
      {:hackney_response, _, {:headers, proplist}} ->
        proplist |> Enum.map(fn {key, val} -> {String.downcase(key), String.downcase(val)} end)
    after 1000 ->
        raise "Timeout while waiting for response to GET request."
    end
    content_length = :proplists.get_value("content-length", header)
    full_content_length = case partial_or_complete do
      :complete ->
        content_length
      :partial ->
        header_line = :proplists.get_value("content-range", header)
        [_, full_length] = String.split(header_line, "/")
        String.to_integer(full_length)
    end
    {content_length, full_content_length}
  end

end
