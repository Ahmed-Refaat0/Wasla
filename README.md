# وصلة

تطبيق Flutter لنقل الملفات مباشرةً بين الأجهزة المتصلة بالشبكة المحلية.

## تنزيل التطبيق

- [تنزيل وصلة لأندرويد (APK)](https://github.com/Ahmed-Refaat0/Wasla/releases/latest/download/Wasla-Android.apk)
- [تنزيل وصلة لويندوز (ZIP)](https://github.com/Ahmed-Refaat0/Wasla/releases/latest/download/Wasla-Windows-x64.zip)
- [عرض كل الإصدارات والتنزيلات](https://github.com/Ahmed-Refaat0/Wasla/releases)

نسخة Android الحالية تجريبية ومخصّصة للاختبار، وليست إصدارًا موقّعًا للنشر على Google Play. على Windows، فك ضغط الملف كاملًا ثم شغّل `wasla.exe`.

## المتطلبات

- Flutter 3.47.7 أو أحدث وDart 3.13 أو أحدث.
- Windows: Visual Studio 2022 مع workload ‏**Desktop development with C++**، بما في ذلك CMake وWindows SDK.
- Android: Android Studio مع Android SDK وPlatform Tools، ثم قبول التراخيص عبر `flutter doctor --android-licenses`.
- Linux: أدوات بناء C++ وCMake وNinja، وخدمة Avahi (`avahi-daemon`).
- iOS وmacOS: جهاز Mac وXcode؛ إعدادات Bonjour والشبكة المحلية موجودة في ملفات المنصات.

## تشغيل التطبيق

من جذر المشروع:

```powershell
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d windows
```

استبدل `windows` بمعرّف الجهاز الذي يظهر في `flutter devices` لتشغيل التطبيق على منصة أخرى. لإنشاء APK تجريبي على Android:

```powershell
flutter build apk --debug
```

### نسخة Windows مستقلة

لبناء التطبيق كنافذة Windows بملفاتها اللازمة للتشغيل، وليس كأمر يحتاج إلى إبقاء الطرفية مفتوحة:

```powershell
flutter build windows --release
```

بعد البناء افتح `build\windows\x64\runner\Release\wasla.exe` مباشرةً. لمشاركة التطبيق، انسخ **مجلد Release كاملًا**؛ لا تنسخ ملف EXE وحده لأن بقية الملفات والمجلدات مطلوبة للتشغيل. يتطلب Windows تثبيت Microsoft Visual C++ Redistributable المناسب لمعمارية الجهاز.

### اتصال مباشر بدون راوتر

- **Android يستضيف الشبكة:** اختر «إنشاء نقطة اتصال» داخل التطبيق، واسمح بإذن الأجهزة القريبة. اتصل باسم الشبكة وكلمة المرور الظاهرين من إعدادات Wi-Fi على Windows أو الجهاز الآخر، مع إبقاء وصلة مفتوحًا على الجهازين.
- **Windows يستضيف الشبكة:** افتح **Settings > Network & Internet > Mobile hotspot** وفعّلها إذا كان محول Wi-Fi يدعم ذلك، ثم صِل Android بها وافتح وصلة على الجهازين.
- نقطة اتصال Android المحلية لا توفر الإنترنت. لا يستطيع التطبيق تشغيل Mobile hotspot على Windows برمجيًا بطريقة تعمل على جميع المحولات وإصدارات Windows، لذا يتم إعدادها من إعدادات النظام.
- إنشاء نقطة الاتصال داخل التطبيق مدعوم على Android 8 فأحدث؛ يطلب Android الإذن اللازم وقت الاستخدام. يعتمد اكتشاف الطرف الآخر على mDNS في الشبكة المباشرة؛ إذا منعت الشبكة اكتشاف mDNS، لا يظهر الجهاز في قائمة الإرسال.

نقل الملفات يستخدم `HttpClient.addStream` وكتابة HTTP الواردة إلى الملف على هيئة تدفقات، فلا يحمّل الملف كاملًا إلى الذاكرة. عمليات الملفات والشبكة غير متزامنة؛ لا ننسخ تدفق النقل إلى Isolate، لأن ذلك يضيف نسخًا للبيانات ويضعف الضغط العكسي. استخدم Isolate فقط عند إضافة عمل كثيف على المعالج مثل ضغط الملفات أو تشفيرها أو حساب checksum.

## تجربة النقل

1. شغّل التطبيق على جهازين متصلين بشبكة Wi-Fi نفسها.
2. على الجهاز المرسل، اختر جهازًا قريبًا، ثم اختر الملفات أو أفلتها في منطقة الإرسال على الكمبيوتر.
3. وافق على طلب الاستقبال من الجهاز المستلم.
4. تُحفظ الملفات في `Downloads/Wasla` إن كان مجلد التنزيلات متاحًا؛ وإلا في مجلد مستندات التطبيق.

يستمع مستقبل الملفات إلى HTTP على المنفذ `53317`. قد يطلب جدار حماية Windows السماح للتطبيق باتصالات الشبكة الخاصة. على Linux يلزم تشغيل Avahi والسماح بـ mDNS عبر UDP/5353. استخدم شبكة موثوقة فقط: النقل المحلي الحالي يستخدم HTTP غير المشفّر.

## ملاحظات المنصات

- iOS يطلب إذن الشبكة المحلية ويعلن خدمة Bonjour `_wasla._tcp`.
- ملف `ios/Podfile` يحدد حد iOS الأدنى لتوافق Bonsoir.
- macOS يحتاج أذونات عميل وخادم الشبكة، بالإضافة إلى Bonjour.
- Android يصرّح بإذن الإنترنت ويسمح باتصالات HTTP التي يستخدمها النقل المحلي.
- المحاكيات والشبكات المعزولة للضيوف قد لا تسمح باكتشاف الأجهزة عبر mDNS.
