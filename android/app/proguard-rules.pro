# O plugin de OCR referencia os reconhecedores de chinês, japonês e coreano,
# mas só embarcamos o modelo latino. Sem estas regras o R8 falha o release.
-dontwarn com.google.mlkit.**
-keep class com.google.mlkit.** { *; }

# ML Kit depende do Google Play Services.
-dontwarn com.google.android.gms.**
