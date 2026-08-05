using System.Buffers.Binary;
using System.Text;

// Standalone smoke test for the 0x07 Equipment packet wire format (no test framework
// dependency — mirrors the exact encode logic in GameBridge.SendEquipmentAsync /
// ClientSession.EnqueueEquipment and the decode logic in GameBridge.ReceiveLoopAsync /
// ClientSession.RunAsync, since those helpers are private and network-stream-coupled).
//
// Run with: dotnet run --project KcdMp.Tests

int failures = 0;

void Check(bool condition, string label)
{
    if (condition)
    {
        Console.WriteLine($"  [PASS] {label}");
    }
    else
    {
        Console.WriteLine($"  [FAIL] {label}");
        failures++;
    }
}

// -------------------------------------------------------------------------
// C→S 0x07 Equipment: [clothingLen:1][clothing:UTF-8][weaponLen:1][weapon:UTF-8]
// -------------------------------------------------------------------------
byte[] EncodeClientEquipment(string clothingGuid, string weaponGuid)
{
    var clothingBytes = Encoding.UTF8.GetBytes(clothingGuid);
    var weaponBytes   = Encoding.UTF8.GetBytes(weaponGuid);
    var payload = new byte[1 + clothingBytes.Length + 1 + weaponBytes.Length];

    int off = 0;
    payload[off++] = (byte)clothingBytes.Length;
    clothingBytes.CopyTo(payload, off); off += clothingBytes.Length;
    payload[off++] = (byte)weaponBytes.Length;
    weaponBytes.CopyTo(payload, off);
    return payload;
}

(string clothing, string weapon) DecodeServerSideEquipment(byte[] payload)
{
    int off = 0;
    int clothingLen = payload[off++];
    string clothing = clothingLen > 0 ? Encoding.UTF8.GetString(payload, off, clothingLen) : "";
    off += clothingLen;
    int weaponLen = off < payload.Length ? payload[off++] : 0;
    string weapon = weaponLen > 0 ? Encoding.UTF8.GetString(payload, off, weaponLen) : "";
    return (clothing, weapon);
}

// -------------------------------------------------------------------------
// S→C 0x07 Equipment: [ghostId:1][clothingLen:1][clothing:UTF-8][weaponLen:1][weapon:UTF-8]
// -------------------------------------------------------------------------
byte[] EncodeServerEquipment(byte ghostId, string clothingGuid, string weaponGuid)
{
    var clothingBytes = Encoding.UTF8.GetBytes(clothingGuid);
    var weaponBytes   = Encoding.UTF8.GetBytes(weaponGuid);
    var payload = new byte[1 + 1 + clothingBytes.Length + 1 + weaponBytes.Length];

    int off = 0;
    payload[off++] = ghostId;
    payload[off++] = (byte)clothingBytes.Length;
    clothingBytes.CopyTo(payload, off); off += clothingBytes.Length;
    payload[off++] = (byte)weaponBytes.Length;
    weaponBytes.CopyTo(payload, off);
    return payload;
}

(byte ghostId, string clothing, string weapon) DecodeClientSideEquipment(byte[] payload)
{
    byte ghostId = payload[0];
    int off = 1;
    int clothingLen = payload[off++];
    string clothing = clothingLen > 0 ? Encoding.UTF8.GetString(payload, off, clothingLen) : "";
    off += clothingLen;
    int weaponLen = off < payload.Length ? payload[off++] : 0;
    string weapon = weaponLen > 0 ? Encoding.UTF8.GetString(payload, off, weaponLen) : "";
    return (ghostId, clothing, weapon);
}

byte[] BuildPacket(byte type, byte[] payload)
{
    var packet = new byte[3 + payload.Length];
    packet[0] = type;
    BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payload.Length);
    payload.CopyTo(packet, 3);
    return packet;
}

Console.WriteLine("=== 0x07 Equipment packet round-trip tests ===");

// Test 1: C→S round trip, both fields populated
{
    var clothing = "dc000003-0000-0000-0000-000000000000";
    var weapon   = "af2dd849-92a4-4081-9955-0afcb861fcd5";
    var payload  = EncodeClientEquipment(clothing, weapon);
    var packet   = BuildPacket(0x07, payload);

    Check(packet[0] == 0x07, "C→S packet type byte is 0x07");
    int payloadLen = BinaryPrimitives.ReadUInt16LittleEndian(packet.AsSpan(1));
    Check(payloadLen == payload.Length, "C→S header payloadLen matches payload length");

    var (decClothing, decWeapon) = DecodeServerSideEquipment(payload);
    Check(decClothing == clothing, "C→S clothing GUID round-trips");
    Check(decWeapon == weapon, "C→S weapon GUID round-trips");
}

// Test 2: C→S round trip, weapon empty (current real-world case — no verified read API)
{
    var clothing = "dc000001-0000-0000-0000-000000000000";
    var payload  = EncodeClientEquipment(clothing, "");
    var (decClothing, decWeapon) = DecodeServerSideEquipment(payload);
    Check(decClothing == clothing, "C→S clothing GUID round-trips (empty weapon)");
    Check(decWeapon == "", "C→S weapon GUID decodes to empty string");
}

// Test 3: S→C round trip, ghostId preserved alongside both GUIDs
{
    byte ghostId = 42;
    var clothing = "dc000002-0000-0000-0000-000000000000";
    var weapon   = "";
    var payload  = EncodeServerEquipment(ghostId, clothing, weapon);
    var packet   = BuildPacket(0x07, payload);

    Check(packet[0] == 0x07, "S→C packet type byte is 0x07");
    var (decGhostId, decClothing, decWeapon) = DecodeClientSideEquipment(payload);
    Check(decGhostId == ghostId, "S→C ghostId round-trips");
    Check(decClothing == clothing, "S→C clothing GUID round-trips");
    Check(decWeapon == weapon, "S→C weapon GUID round-trips (empty)");
}

// Test 4: relay broadcast is a pure re-encode — decoding what the client sent, then
// re-encoding with a ghostId, must reproduce byte-identical clothing/weapon segments.
{
    var clothing = "dc000003-0000-0000-0000-000000000000";
    var weapon   = "af2dd849-92a4-4081-9955-0afcb861fcd5";
    var clientPayload = EncodeClientEquipment(clothing, weapon);
    var (relayedClothing, relayedWeapon) = DecodeServerSideEquipment(clientPayload);

    byte assignedGhostId = 7;
    var serverPayload = EncodeServerEquipment(assignedGhostId, relayedClothing, relayedWeapon);
    var (finalGhostId, finalClothing, finalWeapon) = DecodeClientSideEquipment(serverPayload);

    Check(finalGhostId == assignedGhostId, "Broadcast preserves assigned ghostId");
    Check(finalClothing == clothing, "Broadcast preserves clothing GUID end-to-end");
    Check(finalWeapon == weapon, "Broadcast preserves weapon GUID end-to-end");
}

Console.WriteLine();
if (failures == 0)
{
    Console.WriteLine("All tests passed.");
    return 0;
}

Console.WriteLine($"{failures} test(s) FAILED.");
return 1;
