defmodule BeamClaw.Tool.WebFetch do
  @moduledoc """
  Fetch content from URLs with HTML stripping and truncation.

  Uses Finch for HTTP requests with redirect following and timeout handling.
  """

  @max_chars 50_000
  @max_redirects 5
  @timeout 30_000

  @doc """
  Fetch content from a URL.

  ## Options

    * `:max_chars` - Maximum characters to return (default: 50,000)
    * `:max_redirects` - Maximum redirects to follow (default: 5)
    * `:timeout` - Request timeout in milliseconds (default: 30,000)

  ## Returns

    * `{:ok, %{url: url, content: text, content_type: type, status: int}}`
    * `{:error, reason}`

  ## Examples

      iex> WebFetch.fetch("https://example.com")
      {:ok, %{url: "https://example.com", content: "Example Domain...", content_type: "text/html", status: 200}}
  """
  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    max_chars = Keyword.get(opts, :max_chars, @max_chars)
    max_redirects = Keyword.get(opts, :max_redirects, @max_redirects)
    timeout = Keyword.get(opts, :timeout, @timeout)

    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        do_fetch(url, max_chars, max_redirects, timeout, 0)

      _ ->
        {:error, :invalid_url}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  ## Private Functions

  defp do_fetch(_url, _max_chars, max_redirects, _timeout, redirect_count)
       when redirect_count > max_redirects do
    {:error, :too_many_redirects}
  end

  defp do_fetch(url, max_chars, max_redirects, timeout, redirect_count) do
    request = Finch.build(:get, url)

    case Finch.request(request, BeamClaw.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}}
      when status in 200..299 ->
        content_type = get_content_type(headers)
        processed_content = process_content(body, content_type, max_chars)

        {:ok,
         %{
           url: url,
           content: processed_content,
           content_type: content_type,
           status: status
         }}

      {:ok, %Finch.Response{status: status, headers: headers}}
      when status in 300..399 ->
        # Handle redirect
        case get_location(headers) do
          nil ->
            {:error, :redirect_without_location}

          location ->
            # Resolve relative URLs
            new_url = resolve_url(url, location)
            do_fetch(new_url, max_chars, max_redirects, timeout, redirect_count + 1)
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Mint.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_content_type(headers) do
    Enum.find_value(headers, "text/plain", fn
      {key, value} when key in ["content-type", "Content-Type"] ->
        value |> String.split(";") |> List.first() |> String.trim()

      _ ->
        nil
    end)
  end

  defp get_location(headers) do
    Enum.find_value(headers, fn
      {key, value} when key in ["location", "Location"] -> value
      _ -> nil
    end)
  end

  defp resolve_url(base_url, relative_url) do
    URI.merge(base_url, relative_url) |> to_string()
  end

  defp process_content(body, content_type, max_chars) do
    content =
      if String.contains?(content_type, "html") do
        strip_html(body)
      else
        body
      end

    # Decode HTML entities
    content = decode_html_entities(content)

    # Normalize whitespace
    content = String.replace(content, ~r/\s+/, " ")

    # Truncate to max chars
    String.slice(content, 0, max_chars)
  end

  defp strip_html(html) do
    # Remove script and style tags with their content
    html = Regex.replace(~r/<script\b[^>]*>[\s\S]*?<\/script>/i, html, " ")
    html = Regex.replace(~r/<style\b[^>]*>[\s\S]*?<\/style>/i, html, " ")

    # Remove all HTML tags
    html = Regex.replace(~r/<[^>]*>/, html, " ")

    html
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end
end
