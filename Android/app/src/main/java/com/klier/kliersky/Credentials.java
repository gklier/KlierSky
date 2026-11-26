package com.klier.kliersky;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Device read-only credentials encrypted with a key kept in Android Keystore. */
final class Credentials {
  private final String alias;
  private final SharedPreferences preferences;

  Credentials(Context context) {
    this(context, false);
  }

  Credentials(Context context, boolean owner) {
    alias = owner ? "KlierSky.ownerAccess" : "KlierSky.deviceAccess";
    preferences =
        context.getSharedPreferences(
            owner ? "private-owner-access" : "private-device-access", Context.MODE_PRIVATE);
  }

  private SecretKey key() throws Exception {
    KeyStore store = KeyStore.getInstance("AndroidKeyStore");
    store.load(null);
    if (store.containsAlias(alias))
      return ((KeyStore.SecretKeyEntry) store.getEntry(alias, null)).getSecretKey();
    KeyGenerator generator =
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
    generator.init(
        new KeyGenParameterSpec.Builder(
                alias, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build());
    return generator.generateKey();
  }

  String read() {
    try {
      String raw = preferences.getString("record", "");
      if (raw.isEmpty()) return "";
      String[] parts = raw.split(":");
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(
          Cipher.DECRYPT_MODE,
          key(),
          new GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)));
      return new String(
          cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)),
          java.nio.charset.StandardCharsets.UTF_8);
    } catch (Exception ignored) {
      return "";
    }
  }

  void clear() {
    preferences.edit().remove("record").apply();
  }

  void save(String record) throws Exception {
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.ENCRYPT_MODE, key());
    String encrypted =
        Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP)
            + ":"
            + Base64.encodeToString(
                cipher.doFinal(record.getBytes(java.nio.charset.StandardCharsets.UTF_8)),
                Base64.NO_WRAP);
    if (!preferences.edit().putString("record", encrypted).commit())
      throw new java.io.IOException("Credential storage unavailable");
  }
}
