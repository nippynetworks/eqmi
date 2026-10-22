defmodule Eqmi.UIM.EF do
  @moduledoc """
  The elementary files on a SIM that identify the subscription, and how to
  read them with UIM `Read Transparent`: the file ids and paths (3GPP TS
  31.102) and the decoding of what comes back.

      params = Eqmi.UIM.File.read_transparent(:imsi)
      {:ok, %{read_result: bytes}} = Eqmi.query(dev, uim, :read_transparent, params)
      Eqmi.UIM.File.imsi(bytes)
      #=> "234300123456789"

  Files: `:iccid` (EF_ICCID), `:imsi` (EF_IMSI), `:ad` (EF_AD, the
  administrative data that says how long the MNC is), `:spn` (EF_SPN, the
  service provider name), `:gid1` and `:gid2` (group identifiers, which
  tell a virtual operator's SIMs apart).
  """

  @files %{
    iccid: {0x2FE2, [0x3F00]},
    imsi: {0x6F07, [0x3F00, 0x7FFF]},
    ad: {0x6FAD, [0x3F00, 0x7FFF]},
    spn: {0x6F46, [0x3F00, 0x7FFF]},
    gid1: {0x6F3E, [0x3F00, 0x7FFF]},
    gid2: {0x6F3F, [0x3F00, 0x7FFF]}
  }

  # the primary GW provisioning session: the 3GPP application the modem uses
  @primary_gw_session [session_type: 0, application_identifier: []]

  @type file :: :iccid | :imsi | :ad | :spn | :gid1 | :gid2

  @doc "File id and path (file ids from the MF down) of a file."
  @spec ef(file()) :: {non_neg_integer(), [non_neg_integer()]}
  def ef(name), do: Map.fetch!(@files, name)

  @doc """
  The parameters of a `Read Transparent` request for a whole file, on the
  primary GW provisioning session unless another is given.
  """
  @spec read_transparent(file(), keyword()) :: keyword()
  def read_transparent(name, session \\ @primary_gw_session) do
    {id, path} = ef(name)

    [
      session: session,
      file: [file_id: id, file_path: path_bytes(path)],
      read_information: [offset: 0, length: 0]
    ]
  end

  # the path is sent as 16-bit file ids, little-endian, MF first
  defp path_bytes(path), do: Enum.flat_map(path, fn id -> [rem(id, 256), div(id, 256)] end)

  @doc "ICCID from EF_ICCID: swapped BCD, padding stripped."
  @spec iccid([byte()] | binary()) :: String.t()
  def iccid(bytes), do: bytes |> to_list() |> swapped_bcd() |> String.trim_trailing("f")

  @doc "IMSI from EF_IMSI: a length byte, then swapped BCD after a parity nibble."
  @spec imsi([byte()] | binary()) :: String.t() | nil
  def imsi(bytes) do
    case to_list(bytes) do
      [len | rest] when len > 0 and len <= length(rest) ->
        digits = rest |> Enum.take(len) |> swapped_bcd()
        # the first nibble is parity, the IMSI is 15 digits at most
        digits |> String.slice(1..-1//1) |> String.trim_trailing("f") |> String.slice(0, 15)

      _ ->
        nil
    end
  end

  # North America and a few others number their MNCs with three digits
  @three_digit_mnc_mccs ~w(302 310 311 312 313 314 315 316 330 334 338 342 344 346 348 350 352 354 356 358 360 362 363 364 365 366 368 370 372 374 376 405 708 714)

  @doc """
  MCC and MNC from an IMSI. The MNC is three digits where EF_AD says so
  (its fourth byte, when present) or for the countries that use three,
  two otherwise.
  """
  @spec mcc_mnc(String.t(), [byte()] | binary() | nil) :: {String.t(), String.t()} | nil
  def mcc_mnc(imsi, ad \\ nil)

  def mcc_mnc(<<mcc::binary-size(3), rest::binary>>, ad) when byte_size(rest) >= 2 do
    len =
      case ad && to_list(ad) do
        [_, _, _, n | _] when n in [2, 3] -> n
        _ -> if mcc in @three_digit_mnc_mccs, do: 3, else: 2
      end

    {mcc, String.slice(rest, 0, len)}
  end

  def mcc_mnc(_imsi, _ad), do: nil

  @doc """
  Service provider name from EF_SPN: a display-condition byte, then the
  name in the GSM 7-bit alphabet (one character per byte) or, after a
  0x80 marker, in UCS-2; nil when the file is empty.
  """
  @spec spn([byte()] | binary()) :: String.t() | nil
  def spn(bytes) do
    case to_binary(bytes) do
      <<_condition, 0x80, ucs2::binary>> ->
        ucs2 |> strip_ff() |> from_ucs2be()

      <<_condition, name::binary>> ->
        case name |> strip_ff() |> Eqmi.Text.from_gsm7_unpacked() do
          "" -> nil
          s -> s
        end

      _ ->
        nil
    end
  end

  @doc "A group identifier (EF_GID1, EF_GID2) as upper-case hex, padding stripped."
  @spec gid([byte()] | binary()) :: String.t()
  def gid(bytes), do: bytes |> to_binary() |> strip_ff() |> Base.encode16()

  defp swapped_bcd(bytes) do
    bytes
    |> Enum.map_join(fn b -> <<rem(b, 16)::4, div(b, 16)::4>> |> Base.encode16(case: :lower) end)
  end

  defp strip_ff(bin), do: String.trim_trailing(bin, <<0xFF>>)

  defp from_ucs2be(bin) when rem(byte_size(bin), 2) == 0 and bin != <<>> do
    case :unicode.characters_to_binary(bin, {:utf16, :big}, :utf8) do
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp from_ucs2be(_bin), do: nil

  defp to_list(bytes) when is_binary(bytes), do: :binary.bin_to_list(bytes)
  defp to_list(bytes) when is_list(bytes), do: bytes

  defp to_binary(bytes) when is_list(bytes), do: :binary.list_to_bin(bytes)
  defp to_binary(bytes) when is_binary(bytes), do: bytes
end
