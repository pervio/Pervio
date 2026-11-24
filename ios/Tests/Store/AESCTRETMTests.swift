import XCTest
import CommonCrypto
import Crypto
import NIOCore
import NIOSSH
@testable import Pervio

/// B4: `AES128CTRETM` is hand-rolled transport crypto — the bytes of every
/// keystroke, every private path, every command the phone sends ride through
/// these two methods. Nothing in the app or in NIOSSH tests them: the scheme is
/// only *registered*, and against a server that offers AES-GCM (most of them)
/// this code never runs, so a defect here stays invisible until the one server
/// that forces CTR — and then it is either a hang, or, far worse, a connection
/// that looks fine while accepting forged packets.
///
/// Everything below is checked against implementations that are NOT this file:
///
///  * the AES-CTR keystream against an independent CTR built from CommonCrypto's
///    AES-ECB, which is itself pinned first to the published NIST SP 800-38A
///    F.5.1 vector — so a wrong counter mode / wrong endianness cannot agree
///    with it,
///  * the MAC against CommonCrypto's `CCHmac`, over the exact byte string
///    OpenSSH's `-etm@openssh.com` specifies (sequence ‖ clear length ‖
///    ciphertext),
///  * and the round trip against a second instance of the class keyed as the
///    peer, so "encrypt" and "decrypt" are never allowed to be wrong in the same
///    direction and call it a pass.
///
/// No network, no server: these are pure byte tests.
final class AESCTRETMTests: XCTestCase {

    // MARK: - Independent reference implementations (no production code involved)

    /// One AES-128 ECB block encryption via CommonCrypto — the primitive every
    /// CTR mode is built from.
    private func aesECBBlock(key: [UInt8], _ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionECBMode),
                             key, key.count, nil,
                             block, block.count, &out, out.count, &moved)
        precondition(status == CCCryptorStatus(kCCSuccess) && moved == 16, "AES-ECB failed")
        return out
    }

    /// AES-128-CTR with a full 128-bit big-endian counter — the mode
    /// `kCCModeOptionCTR_BE` names, written out by hand so agreeing with it
    /// means something.
    private func referenceCTR(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var counter = iv
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            let keystream = aesECBBlock(key: key, counter)
            for k in 0..<min(16, data.count - i) { out.append(data[i + k] ^ keystream[k]) }
            var j = 15
            while j >= 0 {                       // big-endian +1 over the whole block
                counter[j] = counter[j] &+ 1
                if counter[j] != 0 { break }
                j -= 1
            }
            i += 16
        }
        return out
    }

    private func hmacSHA256(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, data, data.count, &out)
        return out
    }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let a = s.index(s.startIndex, offsetBy: $0)
            let b = s.index(a, offsetBy: 2)
            return UInt8(s[a..<b], radix: 16)!
        }
    }
    private func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    // MARK: - Fixtures

    /// Distinct, non-zero material per direction, so a mixed-up key or IV can
    /// never accidentally still work.
    private let clientToServerKey = [UInt8](repeating: 0x11, count: 16)
    private let clientToServerIV  = [UInt8]((0..<16).map { UInt8(0xA0 &+ $0) })
    private let clientToServerMAC = [UInt8](repeating: 0x22, count: 32)
    private let serverToClientKey = [UInt8](repeating: 0x33, count: 16)
    private let serverToClientIV  = [UInt8]((0..<16).map { UInt8(0x50 &+ $0) })
    private let serverToClientMAC = [UInt8](repeating: 0x44, count: 32)

    private func keys(clientSide: Bool) -> NIOSSHSessionKeys {
        NIOSSHSessionKeys(
            initialInboundIV:  clientSide ? serverToClientIV  : clientToServerIV,
            initialOutboundIV: clientSide ? clientToServerIV  : serverToClientIV,
            inboundEncryptionKey:  SymmetricKey(data: clientSide ? serverToClientKey : clientToServerKey),
            outboundEncryptionKey: SymmetricKey(data: clientSide ? clientToServerKey : serverToClientKey),
            inboundMACKey:  SymmetricKey(data: clientSide ? serverToClientMAC : clientToServerMAC),
            outboundMACKey: SymmetricKey(data: clientSide ? clientToServerMAC : serverToClientMAC))
    }

    private func makePair() throws -> (client: AES128CTRETM, server: AES128CTRETM) {
        (try AES128CTRETM(initialKeys: keys(clientSide: true), mac: AES128CTRETM.macNames[0]),
         try AES128CTRETM(initialKeys: keys(clientSide: false), mac: AES128CTRETM.macNames[0]))
    }

    /// Encrypt one payload through the production send path and return the wire
    /// bytes (length ‖ ciphertext ‖ mac).
    private func send(_ payload: [UInt8], through p: AES128CTRETM, seq: UInt32) throws -> [UInt8] {
        // Allocated the way NIOSSH allocates it — an empty `ByteBuffer()` has no
        // capacity to move the writer index into.
        var buf = ByteBufferAllocator().buffer(capacity: 4096)
        try p.encryptFramedPayload(to: &buf, sequenceNumber: seq) { $0.writeBytes(payload) }
        return buf.readBytes(length: buf.readableBytes)!
    }

    private func receive(_ wire: [UInt8], through p: AES128CTRETM, seq: UInt32) throws -> [UInt8] {
        var buf = ByteBuffer(bytes: wire)
        var out = try p.decryptAndVerifyRemainingPacket(&buf, sequenceNumber: seq)
        return out.readBytes(length: out.readableBytes)!
    }

    // MARK: - The reference itself, pinned to a published vector

    /// If the oracle every other test leans on were wrong in the same way the
    /// production code is wrong, all of them would pass while the phone talked
    /// gibberish. So the oracle is checked FIRST, against NIST SP 800-38A
    /// §F.5.1 (CTR-AES128.Encrypt) — four blocks, published, not ours.
    func testB4_theReferenceCTRMatchesTheNISTSP80038AVector() {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let counter = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plaintext = hex("6bc1bee22e409f96e93d7e117393172a"
                            + "ae2d8a571e03ac9c9eb76fac45af8e51"
                            + "30c81c46a35ce411e5fbc1191a0a52ef"
                            + "f69f2445df4f9b17ad2b417be66c3710")
        let expected = "874d6191b620e3261bef6864990db6ce"
                     + "9806f66b7970fdff8617187bb9fffdff"
                     + "5ae4df3edbd5d35e5b4f09020db03eab"
                     + "1e031dda2fbe03d1792170a0f3009cee"

        XCTAssertEqual(hexString(referenceCTR(key: key, iv: counter, plaintext)), expected,
                       "the test's own AES-CTR is wrong — every assertion built on it below "
                       + "would be measuring nothing")
    }

    // MARK: - What actually goes on the wire

    /// The whole outbound packet, byte for byte, against the independent CTR and
    /// an independent HMAC: the payload really is encrypted (not framed in the
    /// clear), the SSH framing rules hold (clear length, ≥4 bytes of padding,
    /// block-aligned encrypted region), and the tag covers exactly
    /// (sequence ‖ clear length ‖ ciphertext).
    func testB4_outboundPacketIsRealAESCTRAndARealETMTag() throws {
        let (client, _) = try makePair()
        let payload = Array("ssh-userauth publickey /Users/me/.ssh/id_ed25519".utf8)
        let seq: UInt32 = 7

        let wire = try send(payload, through: client, seq: seq)

        let lengthField = Array(wire[0..<4])
        let ciphertext = Array(wire[4..<(wire.count - 32)])
        let mac = Array(wire[(wire.count - 32)...])
        let declared = lengthField.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        XCTAssertEqual(Int(declared), ciphertext.count,
                       "the clear length field must describe the encrypted region")
        XCTAssertEqual(ciphertext.count % 16, 0, "the encrypted region must be block-aligned")

        // The payload must not be readable on the wire.
        XCTAssertFalse(hexString(ciphertext).contains(hexString(payload)),
                       "the payload appears in the clear inside the 'encrypted' region")

        // Decrypt with the independent CTR and check the SSH framing underneath.
        let plaintext = referenceCTR(key: clientToServerKey, iv: clientToServerIV, ciphertext)
        let padding = Int(plaintext[0])
        XCTAssertGreaterThanOrEqual(padding, 4, "SSH requires at least 4 bytes of padding")
        XCTAssertEqual(Array(plaintext[1..<(1 + payload.count)]), payload,
                       "what the independent AES-CTR recovers is not what we asked to send — "
                       + "the production keystream disagrees with AES-128-CTR")
        XCTAssertEqual(1 + payload.count + padding, plaintext.count,
                       "padding_length must describe the trailing padding exactly")

        // And the tag, computed by CommonCrypto over the ETM byte string.
        var macInput: [UInt8] = [0, 0, 0, UInt8(seq)]
        macInput += lengthField
        macInput += ciphertext
        XCTAssertEqual(mac, hmacSHA256(key: clientToServerMAC, macInput),
                       "the MAC is not HMAC-SHA256 over (sequence ‖ clear length ‖ ciphertext) — "
                       + "a peer would reject every packet, or worse, accept a forged one")
    }

    /// Round trip through the peer, over several packets and several payload
    /// sizes — including the sizes where padding has to grow a whole block. The
    /// counter is stateful across packets, so this also proves the two sides
    /// stay in step instead of restarting the keystream per packet (which would
    /// reuse a keystream: the classic catastrophic CTR bug).
    func testB4_roundTripAcrossManyPacketsAndSizes() throws {
        let (client, server) = try makePair()
        let sizes = [0, 1, 10, 14, 15, 16, 17, 31, 32, 200]
        var wires: [[UInt8]] = []
        for (i, n) in sizes.enumerated() {
            let payload = (0..<n).map { UInt8(($0 &* 7 &+ i) & 0xFF) }
            wires.append(try send(payload, through: client, seq: UInt32(i)))
        }
        for (i, n) in sizes.enumerated() {
            let payload = (0..<n).map { UInt8(($0 &* 7 &+ i) & 0xFF) }
            let got = try receive(wires[i], through: server, seq: UInt32(i))
            XCTAssertEqual(got, payload,
                           "packet \(i) (payload \(n) bytes) did not survive the round trip")
        }

        // Keystream reuse check: two packets of the same length and the same
        // payload must NOT produce the same ciphertext.
        let (c2, _) = try makePair()
        let same = Array("aaaaaaaaaaaaaaaa".utf8)
        let first = try send(same, through: c2, seq: 0)
        let second = try send(same, through: c2, seq: 1)
        XCTAssertNotEqual(Array(first[4..<(first.count - 32)]),
                          Array(second[4..<(second.count - 32)]),
                          "the same payload encrypted twice produced the same ciphertext — the "
                          + "counter is not advancing, so the keystream is being reused")
    }

    // MARK: - Forgeries must be refused

    /// A flipped bit anywhere in the ciphertext must be refused — and refused
    /// BEFORE decryption. The second half is the part that cannot be seen by
    /// looking at one packet: if the packet were decrypted first and only then
    /// checked, the CTR counter would have advanced, and every *legitimate*
    /// packet after the forgery would decode to garbage.
    func testB4_aFlippedCiphertextBitIsRefusedWithoutDesyncingTheStream() throws {
        let (client, server) = try makePair()
        let payload = Array("rm -rf ~/work".utf8)
        let forged = try send(payload, through: client, seq: 0)
        let good = try send(Array("echo ok".utf8), through: client, seq: 1)

        for position in [4, 8, 20] {
            var tampered = forged
            tampered[position] ^= 0x01
            XCTAssertThrowsError(try receive(tampered, through: server, seq: 0),
                                 "a packet with a flipped ciphertext bit was ACCEPTED at byte "
                                 + "\(position) — the transport is unauthenticated")
        }

        XCTAssertEqual(try receive(forged, through: server, seq: 0), payload,
                       "the genuine packet no longer decrypts after a rejected forgery — the "
                       + "forgery was decrypted before its MAC was checked, and the cipher "
                       + "state moved with it")
        XCTAssertEqual(try receive(good, through: server, seq: 1), Array("echo ok".utf8))
    }

    /// A tampered tag, and a truncated one.
    func testB4_aTamperedMacIsRefused() throws {
        let (client, server) = try makePair()
        let wire = try send(Array("git push --force".utf8), through: client, seq: 0)

        var flipped = wire
        flipped[flipped.count - 1] ^= 0x80
        XCTAssertThrowsError(try receive(flipped, through: server, seq: 0),
                             "a packet whose MAC was altered was accepted")

        var zeroed = wire
        for i in (wire.count - 32)..<wire.count { zeroed[i] = 0 }
        XCTAssertThrowsError(try receive(zeroed, through: server, seq: 0),
                             "a packet with an all-zero MAC was accepted")
    }

    /// The sequence number is inside the tag, which is what stops a captured
    /// packet from being replayed (or reordered) later in the session.
    func testB4_aReplayedPacketUnderAnotherSequenceNumberIsRefused() throws {
        let (client, server) = try makePair()
        let wire = try send(Array("sudo shutdown -h now".utf8), through: client, seq: 3)

        XCTAssertThrowsError(try receive(wire, through: server, seq: 4),
                             "the same packet verified under a DIFFERENT sequence number — the "
                             + "sequence is not in the MAC, so a captured packet can be "
                             + "replayed or reordered")
    }

    /// Malformed frames: too short to hold a tag, a ciphertext that isn't
    /// block-aligned, and a *validly tagged* packet whose padding_length lies.
    /// The last one is only reachable by forging with the real MAC key, which
    /// the test has — it is the check that stops a hostile server from steering
    /// `removeLast` off the end of the buffer.
    func testB4_malformedFramesAreRefused() throws {
        let (client, server) = try makePair()
        let wire = try send(Array("hello".utf8), through: client, seq: 0)

        XCTAssertThrowsError(try receive(Array(wire.prefix(20)), through: server, seq: 0),
                             "a packet too short to contain a MAC was accepted")

        var misaligned = wire
        misaligned.insert(0x00, at: 5)          // ciphertext no longer a multiple of 16
        XCTAssertThrowsError(try receive(misaligned, through: server, seq: 0),
                             "a ciphertext that is not block-aligned was accepted")

        for lyingPadding in [UInt8(0), UInt8(3), UInt8(200)] {
            let (_, fresh) = try makePair()
            var plaintext: [UInt8] = [lyingPadding]
            plaintext += Array("hello".utf8)
            plaintext += [UInt8](repeating: 0, count: 16 - (1 + 5) % 16)
            let ciphertext = referenceCTR(key: clientToServerKey, iv: clientToServerIV, plaintext)
            let lengthField: [UInt8] = [0, 0, 0, UInt8(ciphertext.count)]
            let mac = hmacSHA256(key: clientToServerMAC, [0, 0, 0, 0] + lengthField + ciphertext)
            XCTAssertThrowsError(try receive(lengthField + ciphertext + mac, through: fresh, seq: 0),
                                 "a correctly-tagged packet whose padding_length was \(lyingPadding) "
                                 + "was accepted — padding_length is attacker-chosen input")
        }
    }

    /// Rekeying (SSH renegotiates keys on a long-lived session) must actually
    /// take: after `updateKeys` the old keys must no longer verify, and the new
    /// ones must.
    func testB4_updateKeysSwitchesBothDirections() throws {
        let (client, server) = try makePair()
        _ = try send(Array("before rekey".utf8), through: client, seq: 0)

        let fresh = NIOSSHSessionKeys(
            initialInboundIV: clientToServerIV, initialOutboundIV: serverToClientIV,
            inboundEncryptionKey: SymmetricKey(data: [UInt8](repeating: 0x55, count: 16)),
            outboundEncryptionKey: SymmetricKey(data: [UInt8](repeating: 0x66, count: 16)),
            inboundMACKey: SymmetricKey(data: [UInt8](repeating: 0x77, count: 32)),
            outboundMACKey: SymmetricKey(data: [UInt8](repeating: 0x88, count: 32)))
        try client.updateKeys(NIOSSHSessionKeys(
            initialInboundIV: serverToClientIV, initialOutboundIV: clientToServerIV,
            inboundEncryptionKey: SymmetricKey(data: [UInt8](repeating: 0x66, count: 16)),
            outboundEncryptionKey: SymmetricKey(data: [UInt8](repeating: 0x55, count: 16)),
            inboundMACKey: SymmetricKey(data: [UInt8](repeating: 0x88, count: 32)),
            outboundMACKey: SymmetricKey(data: [UInt8](repeating: 0x77, count: 32))))

        let afterRekey = try send(Array("after rekey".utf8), through: client, seq: 1)
        XCTAssertThrowsError(try receive(afterRekey, through: server, seq: 1),
                             "the peer still on the OLD keys accepted a packet sent under the "
                             + "new ones — updateKeys did not take")

        try server.updateKeys(fresh)
        XCTAssertEqual(try receive(afterRekey, through: server, seq: 1), Array("after rekey".utf8),
                       "after both sides rekeyed the session must keep working")
    }
}
