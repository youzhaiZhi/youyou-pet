# security-crypto 依赖的 Tink 会引用一批「编译期注解」，运行时并不需要。
# R8 在 minify 阶段会因为找不到这些类而直接报错，这里统一放行。
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn javax.annotation.concurrent.**

# 保留 Tink / security-crypto 的反射入口
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**