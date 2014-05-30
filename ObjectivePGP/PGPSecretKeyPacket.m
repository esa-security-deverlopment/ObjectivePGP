//
//  PGPSecretKeyPacket.m
//  ObjectivePGP
//
//  Created by Marcin Krzyzanowski on 07/05/14.
//  Copyright (c) 2014 Marcin Krzyżanowski. All rights reserved.
//
//  A Secret-Key packet contains all the information that is found in a
//  Public-Key packet, including the public-key material, but also
//  includes the secret-key material after all the public-key fields.

#import "PGPSecretKeyPacket.h"
#import "PGPS2K.h"
#import "PGPMPI.h"

#import "PGPCryptoUtils.h"
#import "NSData+PGPUtils.h"

#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonCryptor.h>

#include <openssl/cast.h>
#include <openssl/idea.h>
#include <openssl/aes.h>
#include <openssl/sha.h>
#include <openssl/des.h>
#include <openssl/camellia.h>
#include <openssl/blowfish.h>

@interface PGPPacket ()
@property (copy, readwrite) NSData *headerData;
@property (copy, readwrite) NSData *bodyData;
@end

@interface PGPSecretKeyPacket ()
@property (strong, readwrite) NSData *encryptedMPIsPartData; // after decrypt -> secretMPIArray
@property (strong, readwrite) NSData *ivData;
@property (strong, readwrite) NSArray *secretMPIArray; // decrypted MPI
@end

@implementation PGPSecretKeyPacket

- (PGPPacketTag)tag
{
    return PGPSecretKeyPacketTag;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ isEncrypted: %@", [super description], @(self.isEncrypted)];
}

- (BOOL)isEncrypted
{
    return (self.s2kUsage == PGPS2KUsageEncrypted || self.s2kUsage == PGPS2KUsageEncryptedAndHashed);
}

- (PGPMPI *) secretMPI:(NSString *)identifier
{
    __block PGPMPI *returnMPI = nil;
    [self.secretMPIArray enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        PGPMPI *mpi = obj;
        if ([mpi.identifier isEqualToString:identifier]) {
            returnMPI = mpi;
            *stop = YES;
        }
    }];

    return returnMPI;
}

- (PGPFingerprint *)fingerprint
{
    return [super fingerprint];
}

- (NSData *) exportPacket:(NSError *__autoreleasing *)error
{
    NSMutableData *data = [NSMutableData data];
    NSData *publicKeyData = [super buildPublicKeyBodyData:YES];

    NSMutableData *secretKeyPacketData = [NSMutableData data];
    [secretKeyPacketData appendData:publicKeyData];
    [secretKeyPacketData appendData:[self buildSecretKeyDataAndForceV4:YES]];

    NSData *headerData = [self buildHeaderData:secretKeyPacketData];
    [data appendData: headerData];
    [data appendData: secretKeyPacketData];

    // header not allways match because export new format while input can be old format
    NSAssert([secretKeyPacketData isEqualToData:self.bodyData], @"Secret key not match");
    return [data copy];
}

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError *__autoreleasing *)error
{
    NSUInteger position = [super parsePacketBody:packetBody error:error];
    //  5.5.3.  Secret-Key Packet Formats

    NSAssert(self.version == 0x04,@"Only Secret Key version 4 is supported. Found version %@", @(self.version));

    // One octet indicating string-to-key usage conventions
    [packetBody getBytes:&_s2kUsage range:(NSRange){position, 1}];
    position = position + 1;

    if (self.s2kUsage == PGPS2KUsageEncrypted || self.s2kUsage == PGPS2KUsageEncryptedAndHashed) {
        // moved to readEncrypted:astartingAtPosition
    } else if (self.s2kUsage != PGPS2KUsageNone) {
        // this is version 3, looks just like a V4 simple hash
        self.symmetricAlgorithm = (PGPSymmetricAlgorithm)self.s2kUsage; // this is tricky, but this is right. V3 algorithm is in place of s2kUsage of V4
        self.s2kUsage = PGPS2KUsageEncrypted;
        
        self.s2k = [[PGPS2K alloc] init]; // not really parsed s2k
        self.s2k.specifier = PGPS2KSpecifierSimple;
        self.s2k.hashAlgorithm = PGPHashMD5;
    }

    NSData *encryptedData = [packetBody subdataWithRange:(NSRange){position, packetBody.length - position}];
    if (self.isEncrypted) {
        position = position + [self parseEncryptedPart:encryptedData error:error];
    } else {
        position = position + [self parseUnencryptedPart:encryptedData error:error];
    }

    return position;
}

/**
 *  Encrypted algorithm-specific fields for secret keys
 *
 *  @param packetBody packet data
 *  @param position   position offset
 *
 *  @return length
 */
- (NSUInteger) parseEncryptedPart:(NSData *)data error:(NSError **)error
{
    NSUInteger position = 0;

    // If string-to-key usage octet was 255 or 254, a one-octet symmetric encryption algorithm
    [data getBytes:&_symmetricAlgorithm range:(NSRange){position, 1}];
    position = position + 1;

    // S2K
    self.s2k = [PGPS2K string2KeyFromData:data atPosition:position];
    position = position + self.s2k.length;

    // Initial Vector (IV) of the same length as the cipher's block size
    NSUInteger blockSize = [PGPCryptoUtils blockSizeOfSymmetricAlhorithm:self.symmetricAlgorithm];
    NSAssert(blockSize <= 16, @"invalid blockSize");

    self.ivData = [data subdataWithRange:(NSRange) {position, blockSize}];
    position = position + blockSize;


    // encrypted MPIs
    // checksum or hash is encrypted together with the algorithm-specific fields (mpis) (if string-to-key usage octet is not zero).
    self.encryptedMPIsPartData = [data subdataWithRange:(NSRange) {position, data.length - position}];
    position = position + self.encryptedMPIsPartData.length;

#ifdef DEBUG
    //[self decrypt:@"1234"];
    //[self decrypt:@"1234" error:error];  // invalid password
#endif
    return data.length;
}

/**
 *  Cleartext part, parse cleartext or unencrypted data
 *  Store decrypted values in secretMPI array
 *
 *  @param packetBody packet data
 *  @param position   position offset
 *
 *  @return length
 */
- (NSUInteger) parseUnencryptedPart:(NSData *)data error:(NSError **)error
{
    NSUInteger position = 0;

    // check hash before read actual data
    // hash is physically located at the end of dataBody
    switch (self.s2kUsage) {
        case PGPS2KUsageEncryptedAndHashed:
        {
            // a 20-octet SHA-1 hash of the plaintext of the algorithm-specific portion.
            NSUInteger hashSize = [PGPCryptoUtils hashSizeOfHashAlhorithm:PGPHashSHA1];
            NSAssert(hashSize <= 20, @"invalid hashSize");

            NSData *clearTextData = [data subdataWithRange:(NSRange) {0, data.length - hashSize}];
            NSData *hashData = [data subdataWithRange:(NSRange){data.length - hashSize, hashSize}];
            NSData *calculatedHashData = [clearTextData pgpSHA1];

            if (![hashData isEqualToData:calculatedHashData]) {
                if (error) {
                    *error = [NSError errorWithDomain:@"objectivepgp.hakore.com" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Decrypted hash mismatch, check password."}];
                    return data.length;
                }
            }

        }
            break;
        default:
        {
            // a two-octet checksum of the plaintext of the algorithm-specific portion
            NSUInteger checksumLength = 2;
            NSData *clearTextData = [data subdataWithRange:(NSRange) {0, data.length - checksumLength}];
            NSData *checksumData = [data subdataWithRange:(NSRange){data.length - checksumLength, checksumLength}];
            NSUInteger calculatedChecksum = [clearTextData pgpChecksum];

            UInt16 checksum = 0;
            [checksumData getBytes:&checksum length:checksumLength];
            checksum = CFSwapInt16BigToHost(checksum);

            if (checksum != calculatedChecksum) {
                if (error) {
                    *error = [NSError errorWithDomain:@"objectivepgp.hakore.com" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Decrypted hash mismatch, check password."}];
                    return data.length;
                }
            }
        }
            break;
    }

    // now read the actual data
    switch (self.publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmRSA:
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
        case PGPPublicKeyAlgorithmRSASignOnly:
        {
            // multiprecision integer (MPI) of RSA secret exponent d.
            PGPMPI *mpiD = [[PGPMPI alloc] initWithMPIData:data atPosition:position];
            mpiD.identifier = @"D";
            position = position + mpiD.packetLength;

            // MPI of RSA secret prime value p.
            PGPMPI *mpiP = [[PGPMPI alloc] initWithMPIData:data atPosition:position];
            mpiP.identifier = @"P";
            position = position + mpiP.packetLength;

            // MPI of RSA secret prime value q (p < q).
            PGPMPI *mpiQ = [[PGPMPI alloc] initWithMPIData:data atPosition:position];
            mpiQ.identifier = @"Q";
            position = position + mpiQ.packetLength;

            // MPI of u, the multiplicative inverse of p, mod q.
            PGPMPI *mpiU = [[PGPMPI alloc] initWithMPIData:data atPosition:position];
            mpiU.identifier = @"U";
            position = position + mpiU.packetLength;

            self.secretMPIArray = [NSArray arrayWithObjects:mpiD, mpiP, mpiQ, mpiU, nil];
        }
            break;
        case PGPPublicKeyAlgorithmDSA:
        {
            // MPI of DSA secret exponent x.
            PGPMPI *mpiX = [[PGPMPI alloc] initWithMPIData:data atPosition:position];
            mpiX.identifier = @"X";
            position = position + mpiX.packetLength;

            self.secretMPIArray = [NSArray arrayWithObjects:mpiX, nil];
        }
            break;
        case PGPPublicKeyAlgorithmElgamal:
        case PGPPublicKeyAlgorithmElgamalEncryptorSign:
        {
            // MPI of Elgamal secret exponent x.
            PGPMPI *mpiX = [[PGPMPI alloc] initWithMPIData:data atPosition:position];
            mpiX.identifier = @"X";
            position = position + mpiX.packetLength;

            self.secretMPIArray = [NSArray arrayWithObjects:mpiX, nil];
        }
            break;
        default:
            break;
    }

    return data.length;
}

/**
 *  Decrypt parsed encrypted packet
 *  Decrypt packet and store decrypted data on instance
 *  TODO: V3 support
 *  TODO: encrypt
 *  NOTE: Decrypted packet data should be released/forget after use
 */
- (BOOL) decrypt:(NSString *)passphrase error:(NSError *__autoreleasing *)error
{
    if (!self.isEncrypted) {
        return NO;
    }

    if (!self.ivData) {
        return NO;
    }

    // Keysize
    NSUInteger keySize = [PGPCryptoUtils keySizeOfSymmetricAlhorithm:self.symmetricAlgorithm];
    NSAssert(keySize <= 32, @"invalid keySize");

    //FIXME: not here, just for testing (?)
    NSData *keyData = [self.s2k produceKeyWithPassphrase:passphrase keySize:keySize];

    const void *encryptedBytes = self.encryptedMPIsPartData.bytes;

    NSUInteger outButterLength = self.encryptedMPIsPartData.length;
    UInt8 *outBuffer = calloc(outButterLength, sizeof(UInt8));

    NSData *decryptedData = nil;

    // decrypt with CFB
    switch (self.symmetricAlgorithm) {
        case PGPSymmetricAES128:
        case PGPSymmetricAES192:
        case PGPSymmetricAES256:
        {
            AES_KEY *encrypt_key = calloc(1, sizeof(AES_KEY));
            AES_set_encrypt_key(keyData.bytes, keySize * 8, encrypt_key);

            AES_KEY *decrypt_key = calloc(1, sizeof(AES_KEY));
            AES_set_decrypt_key(keyData.bytes, keySize * 8, decrypt_key);

            int num = 0;
            AES_cfb128_encrypt(encryptedBytes, outBuffer, outButterLength, decrypt_key, (UInt8 *)self.ivData.bytes, &num, AES_DECRYPT);
            decryptedData = [NSData dataWithBytes:outBuffer length:outButterLength];

            if (encrypt_key) free(encrypt_key);
            if (decrypt_key) free(decrypt_key);
        }
            break;
        case PGPSymmetricIDEA:
        {
            IDEA_KEY_SCHEDULE *encrypt_key = calloc(1, sizeof(IDEA_KEY_SCHEDULE));
            idea_set_encrypt_key(keyData.bytes, encrypt_key);

            IDEA_KEY_SCHEDULE *decrypt_key = calloc(1, sizeof(IDEA_KEY_SCHEDULE));
            idea_set_decrypt_key(encrypt_key, decrypt_key);

            int num = 0;
            idea_cfb64_encrypt(encryptedBytes, outBuffer, outButterLength, decrypt_key, (UInt8 *)self.ivData.bytes, &num, CAST_DECRYPT);
            decryptedData = [NSData dataWithBytes:outBuffer length:outButterLength];

            if (encrypt_key) free(encrypt_key);
            if (decrypt_key) free(decrypt_key);
        }
            break;
        case PGPSymmetricTripleDES:
        {
            DES_key_schedule *keys = calloc(3, sizeof(DES_key_schedule));

            for (NSUInteger n = 0; n < 3; ++n) {
                DES_set_key((DES_cblock *)(void *)(self.ivData.bytes + n * 8),&keys[n]);
            }

            int num = 0;
            DES_ede3_cfb64_encrypt(encryptedBytes, outBuffer, outButterLength, &keys[0], &keys[1], &keys[2], (DES_cblock *)self.ivData.bytes, &num, DES_DECRYPT);
            decryptedData = [NSData dataWithBytes:outBuffer length:outButterLength];

            if (keys) free(keys);
        }
            break;
        case PGPSymmetricCAST5:
        {
            // initialize
            CAST_KEY *encrypt_key = calloc(1, sizeof(CAST_KEY));
            CAST_set_key(encrypt_key, keySize, keyData.bytes);

            CAST_KEY *decrypt_key = calloc(1, sizeof(CAST_KEY));
            CAST_set_key(decrypt_key, keySize, keyData.bytes);

            // see __ops_decrypt_init block_encrypt siv,civ,iv comments. siv is needed for weird v3 resync,
            // wtf civ ???
            // CAST_ecb_encrypt(in, out, encrypt_key, CAST_ENCRYPT);

            //TODO: maybe CommonCrypto with kCCModeCFB in place of OpenSSL
            int num = 0; //	how much of the 64bit block we have used
            CAST_cfb64_encrypt(encryptedBytes, outBuffer, outButterLength, decrypt_key, (UInt8 *)self.ivData.bytes, &num, CAST_DECRYPT);
            decryptedData = [NSData dataWithBytes:outBuffer length:outButterLength];

            if (encrypt_key) free(encrypt_key);
            if (decrypt_key) free(decrypt_key);
        }
            break;
        case PGPSymmetricBlowfish:
        case PGPSymmetricTwofish256:
            //TODO: implement blowfish and twofish
            [NSException raise:@"PGPNotSupported" format:@"Twofish not supported"];
            break;
        case PGPSymmetricPlaintext:
            [NSException raise:@"PGPInconsistency" format:@"Can't decrypt plaintext"];
            break;
        default:
            break;
    }

    if (outBuffer) {
        memset(outBuffer, 0, sizeof(UInt8));
        free(outBuffer);
    }

    // now read mpis
    if (decryptedData) {
        [self parseUnencryptedPart:decryptedData error:error];
        if (*error) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - Private

/**
 *  Build public key data for fingerprint
 *
 *  @return public key data starting with version octet
 */
- (NSData *) buildSecretKeyDataAndForceV4:(BOOL)forceV4
{
    NSAssert(forceV4 == YES,@"Only V4 is supported");

    NSError *exportError = nil;

    NSMutableData *data = [NSMutableData data];
    [data appendBytes:&_s2kUsage length:1];

    switch (self.s2kUsage) {
        case PGPS2KUsageEncrypted:
        case PGPS2KUsageEncryptedAndHashed:
            // If string-to-key usage octet was 255 or 254, a one-octet symmetric encryption algorithm
            [data appendBytes:&_symmetricAlgorithm length:1];

            // S2K
            [data appendData:[self.s2k export:&exportError]];

            // Initial Vector (IV) of the same length as the cipher's block size
            [data appendBytes:self.ivData.bytes length:self.ivData.length];

            // encrypted MPIs
            [data appendData:self.encryptedMPIsPartData];

            // Hash
            [data appendData:[data pgpSHA1]];
            break;
        case PGPS2KUsageNone:
            for (PGPMPI *mpi in self.secretMPIArray) {
                [data appendData:[mpi exportMPI]];
            }

            // Checksum
            UInt16 checksum = CFSwapInt16HostToBig([data pgpChecksum]);
            [data appendBytes:&checksum length:2];
            break;
        default:
            break;
    }

//    } else if (self.s2kUsage != PGPS2KUsageNone) {
//        // this is version 3, looks just like a V4 simple hash
//        self.symmetricAlgorithm = (PGPSymmetricAlgorithm)self.s2kUsage; // this is tricky, but this is right. V3 algorithm is in place of s2kUsage of V4
//        self.s2kUsage = PGPS2KUsageEncrypted;
//
//        self.s2k = [[PGPS2K alloc] init]; // not really parsed s2k
//        self.s2k.specifier = PGPS2KSpecifierSimple;
//        self.s2k.algorithm = PGPHashMD5;



    return [data copy];
}


@end
