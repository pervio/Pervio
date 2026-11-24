import Foundation
import Crypto
import NIOCore
import NIOSSH
import CommonCrypto

/// AES-128-CTR with HMAC-SHA2-256 in **Encrypt-then-MAC** (`-etm@openssh.com`) mode.
///
/// WHY THIS EXISTS
/// ---------------
/// swift-nio-ssh only ships AES-GCM (whose `macNames` is empty) and Citadel's
/// AES-CTR advertises only the *non*-ETM HMACs. A server hardened by `ssh-audit`
/// accepts ONLY `*-etm@openssh.com` MACs, so NIOSSH and the server share no MAC
/// and the handshake dies with `keyExchangeNegotiationFailure`.
///
/// Registering this scheme makes NIOSSH advertise `hmac-sha2-256-etm@openssh.com`,
/// which lets MAC negotiation succeed. In practice, against such a server the
/// CIPHER negotiation still prefers NIOSSH's own `aes128-gcm@openssh.com` (it is
/// earlier in the offer list and the server supports it), so the live connection
/// runs on AES-GCM and the methods below are never exercised. They are
/// nonetheless implemented correctly so the scheme also works on a server that
/// offers no GCM.
///
/// ETM framing (OpenSSH): the 4-byte packet-length is sent in clear; only
/// (padding_length ‖ payload ‖ padding) is encrypted and must be block-aligned;
/// the MAC is computed over (sequence_number ‖ clear_length ‖ ciphertext) and is
/// verified BEFORE decryption.
public final class AES128CTRETM: NIOSSHTransportProtection {
    public static let cipherName = "aes128-ctr"
    public static let macNames = ["hmac-sha2-256-etm@openssh.com"]
    public static let cipherBlockSize = 16

    public static func keySizes(forMac mac: String?) throws -> ExpectedKeySizes {
        ExpectedKeySizes(ivSize: 16, encryptionKeySize: 16, macKeySize: SHA256.byteCount)
    }

    public var macBytes: Int { SHA256.byteCount }   // 32-byte HMAC-SHA256 tag

    private enum ETMError: Error { case cryptorInit, cryptorUpdate, badPacket, badPadding, badMac }

    private var keySizes: ExpectedKeySizes
    private var outboundMACKey: SymmetricKey
    private var inboundMACKey: SymmetricKey
    private var encryptor: CCCryptorRef?
    private var decryptor: CCCryptorRef?

    public init(initialKeys: NIOSSHSessionKeys, mac: String?) throws {
        self.keySizes = try Self.keySizes(forMac: mac)
        self.outboundMACKey = initialKeys.outboundMACKey
        self.inboundMACKey = initialKeys.inboundMACKey
        self.encryptor = try Self.makeCTR(key: initialKeys.outboundEncryptionKey, iv: initialKeys.initialOutboundIV)
        self.decryptor = try Self.makeCTR(key: initialKeys.inboundEncryptionKey, iv: initialKeys.initialInboundIV)
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        outboundMACKey = newKeys.outboundMACKey
        inboundMACKey = newKeys.inboundMACKey
        if let encryptor { CCCryptorRelease(encryptor) }
        if let decryptor { CCCryptorRelease(decryptor) }
        encryptor = try Self.makeCTR(key: newKeys.outboundEncryptionKey, iv: newKeys.initialOutboundIV)
        decryptor = try Self.makeCTR(key: newKeys.inboundEncryptionKey, iv: newKeys.initialInboundIV)
    }

    deinit {
        if let encryptor { CCCryptorRelease(encryptor) }
        if let decryptor { CCCryptorRelease(decryptor) }
    }

    // MARK: AES-CTR via CommonCrypto (stateful: the counter persists across packets)

    private static func makeCTR(key: SymmetricKey, iv: [UInt8]) throws -> CCCryptorRef {
        var cryptor: CCCryptorRef?
        // CTR is symmetric: the same keystream both encrypts and decrypts, so we
        // create both directions with kCCEncrypt.
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress, keyPtr.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), let cryptor else { throw ETMError.cryptorInit }
        return cryptor
    }

    private func crypt(_ cryptor: CCCryptorRef?, _ input: [UInt8]) throws -> [UInt8] {
        guard let cryptor else { throw ETMError.cryptorUpdate }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, input.count,
                                outPtr.baseAddress, outPtr.count, &moved)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), moved == input.count else { throw ETMError.cryptorUpdate }
        return output
    }

    // MARK: NIOSSHTransportProtection

    public func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        // ETM: the length field is plaintext already. Nothing to do.
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        // Layout on the wire: [length(4, clear)] [ciphertext] [mac(macBytes)]
        guard
            let lengthBytes = source.readBytes(length: 4),
            source.readableBytes >= macBytes,
            let ciphertext = source.readBytes(length: source.readableBytes - macBytes),
            let mac = source.readBytes(length: macBytes),
            !ciphertext.isEmpty, ciphertext.count % Self.cipherBlockSize == 0
        else {
            throw ETMError.badPacket
        }

        // Verify MAC over (seq ‖ clear length ‖ ciphertext) BEFORE decrypting.
        var hmac = Crypto.HMAC<SHA256>(key: inboundMACKey)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { hmac.update(data: $0) }
        hmac.update(data: lengthBytes)
        hmac.update(data: ciphertext)
        let ok = hmac.finalize().withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) == mac }
        guard ok else { throw ETMError.badMac }

        // Decrypt (padding_length ‖ payload ‖ padding) and strip the padding.
        var plaintext = try crypt(decryptor, ciphertext)
        let paddingLength = Int(plaintext.first ?? 0)
        guard paddingLength >= 4, paddingLength < plaintext.count else { throw ETMError.badPadding }
        plaintext.removeFirst(1)
        plaintext.removeLast(paddingLength)
        return ByteBuffer(bytes: plaintext)
    }

    public func encryptPacket(_ packet: NIOSSHEncryptablePayload, to outboundBuffer: inout ByteBuffer, sequenceNumber: UInt32) throws {
        try encryptFramedPayload(to: &outboundBuffer, sequenceNumber: sequenceNumber) {
            $0.writeEncryptablePayload(packet)
        }
    }

    /// The whole ETM send path — framing, padding, CTR, MAC — with only "write the
    /// payload bytes into the buffer" left to the caller (it returns how many it
    /// wrote). `encryptPacket` hands it NIOSSH's serializer.
    ///
    /// This exists ONLY as a test seam: `NIOSSHEncryptablePayload` has no public
    /// initializer, so without it no test can reach this code at all — and it is
    /// the code that decides whether what leaves the phone is really encrypted
    /// and really authenticated. A test writes plain bytes here and everything
    /// after that point is the production path, byte for byte.
    func encryptFramedPayload(to outboundBuffer: inout ByteBuffer, sequenceNumber: UInt32,
                              writePayload: (inout ByteBuffer) -> Int) throws {
        let packetLengthIndex = outboundBuffer.writerIndex
        let packetLengthLength = 4
        let packetPaddingIndex = packetLengthIndex + packetLengthLength
        let packetPaddingLength = 1

        outboundBuffer.moveWriterIndex(forwardBy: packetLengthLength + packetPaddingLength)
        let payloadBytes = writePayload(&outboundBuffer)

        // The length field is NOT encrypted, so block-align only
        // (padding_length ‖ payload ‖ padding), with >= 4 bytes of padding.
        var encryptedSize = packetPaddingLength + payloadBytes
        var paddingLength = Self.cipherBlockSize - (encryptedSize % Self.cipherBlockSize)
        if paddingLength < 4 { paddingLength += Self.cipherBlockSize }
        encryptedSize += outboundBuffer.writeSSHPaddingBytes(count: paddingLength)
        precondition(encryptedSize % Self.cipherBlockSize == 0)

        outboundBuffer.setInteger(UInt32(encryptedSize), at: packetLengthIndex)
        outboundBuffer.setInteger(UInt8(paddingLength), at: packetPaddingIndex)

        let plaintext = outboundBuffer.getBytes(at: packetPaddingIndex, length: encryptedSize)!
        let ciphertext = try crypt(encryptor, plaintext)
        let lengthField = outboundBuffer.getBytes(at: packetLengthIndex, length: packetLengthLength)!

        // MAC over (seq ‖ clear length ‖ ciphertext).
        var hmac = Crypto.HMAC<SHA256>(key: outboundMACKey)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { hmac.update(data: $0) }
        hmac.update(data: lengthField)
        hmac.update(data: ciphertext)
        let mac = hmac.finalize()

        outboundBuffer.setBytes(ciphertext, at: packetPaddingIndex)
        outboundBuffer.writeContiguousBytes(mac)
    }
}
