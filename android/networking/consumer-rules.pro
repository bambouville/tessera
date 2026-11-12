# tessera_mosh_jni.cpp resolves the output callback by its JVM name/signature;
# without it every Mosh session aborts the app on connect.
-keepclassmembers class com.bambouville.tessera.networking.mosh.JniMoshNativeClient {
    void onNativeOutput(byte[]);
}
