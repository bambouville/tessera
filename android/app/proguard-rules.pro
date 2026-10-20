# SSHJ exposes optional PuTTY/PEM import readers backed by Bouncy Castle. Tessera's
# Phase B credential boundary accepts only Android Keystore keys and ephemeral
# passwords, and the networking module deliberately excludes Bouncy Castle so it
# cannot intercept AndroidKeyStore signatures. These unreachable optional readers
# are removed by R8; suppress only their missing-class references.
-dontwarn org.bouncycastle.crypto.generators.Argon2BytesGenerator
-dontwarn org.bouncycastle.crypto.params.Argon2Parameters$Builder
-dontwarn org.bouncycastle.crypto.params.Argon2Parameters
-dontwarn org.bouncycastle.openssl.PEMDecryptor
-dontwarn org.bouncycastle.openssl.PEMDecryptorProvider
-dontwarn org.bouncycastle.openssl.PEMException
-dontwarn org.bouncycastle.openssl.bc.BcPEMDecryptorProvider
-dontwarn org.bouncycastle.operator.OperatorCreationException
