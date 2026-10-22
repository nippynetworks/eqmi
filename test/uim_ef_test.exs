defmodule EqmiUimEfTest do
  use ExUnit.Case, async: true
  alias Eqmi.UIM.EF

  test "read transparent parameters name the file by id and path" do
    assert EF.read_transparent(:imsi) == [
             session: [session_type: 0, application_identifier: []],
             file: [file_id: 0x6F07, file_path: [0x00, 0x3F, 0xFF, 0x7F]],
             read_information: [offset: 0, length: 0]
           ]

    assert EF.ef(:iccid) == {0x2FE2, [0x3F00]}
    assert EF.ef(:spn) == {0x6F46, [0x3F00, 0x7FFF]}

    # the request encodes (ids and path little-endian)
    assert <<0x20, 0, _len::little-16, _::binary>> =
             Eqmi.UIM.request(:read_transparent, EF.read_transparent(:imsi))
  end

  test "ICCID and IMSI decode from the card's swapped BCD" do
    # ICCID 8944110068160132534 (19 digits) padded with F
    assert EF.iccid([0x98, 0x44, 0x11, 0x00, 0x86, 0x61, 0x10, 0x23, 0x35, 0xF4]) ==
             "8944110068160132534"

    # IMSI 234300123456789: length 8, parity nibble 9 (odd length) before the digits
    assert EF.imsi([8, 0x29, 0x43, 0x03, 0x10, 0x32, 0x54, 0x76, 0x98]) == "234300123456789"
    assert EF.imsi(<<8, 0x29, 0x43, 0x03, 0x10, 0x32, 0x54, 0x76, 0x98>>) == "234300123456789"
    assert EF.imsi([0]) == nil
    assert EF.imsi(<<>>) == nil
  end

  test "MCC and MNC from the IMSI, with EF_AD or the country deciding the MNC length" do
    assert EF.mcc_mnc("234300123456789") == {"234", "30"}
    assert EF.mcc_mnc("310260123456789") == {"310", "260"}
    assert EF.mcc_mnc("234300123456789", [0, 0, 0, 3]) == {"234", "300"}
    assert EF.mcc_mnc("310260123456789", [0, 0, 0, 2]) == {"310", "26"}
    assert EF.mcc_mnc("12", nil) == nil
  end

  test "service provider name in GSM 7-bit or UCS-2, group identifiers as hex" do
    assert EF.spn([0x01, ?E, ?E, 0xFF, 0xFF, 0xFF]) == "EE"
    assert EF.spn(<<0x00, 0x80, 0x00, ?E, 0x00, ?E, 0xFF, 0xFF>>) == "EE"
    assert EF.spn([0x00, 0xFF, 0xFF]) == nil
    assert EF.spn([]) == nil
    assert EF.gid([0x45, 0x45, 0xFF, 0xFF]) == "4545"
    assert EF.gid(<<0xFF, 0xFF>>) == ""
  end
end
