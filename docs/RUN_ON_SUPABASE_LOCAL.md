# تشغيل اختبار R4 على Supabase المحلي (PostgreSQL 17 + Auth حقيقي)

**لماذا يدويًا؟** بيئة Claude لا تصل إلى سجلات Docker ولا إلى npm/GitHub، فلا يمكن تشغيل `supabase start` هناك. كل ما يلي يعمل على جهازك فقط، ولا يلمس مشروع الإنتاج ولا أي مشروع سحابي.

## المتطلبات
1. Docker Desktop (أو Docker Engine) يعمل: `docker version` يطبع Client وServer.
2. Supabase CLI حديث: `supabase --version` (التثبيت: https://supabase.com/docs/guides/local-development/cli/getting-started).
3. أدوات `psql` (PostgreSQL client) و`bash` (على Windows استعمل WSL أو Git Bash).
4. هذا المجلد (المستودع) بفرع `saai-development` مع ملفات المرحلة 1 (انظر أدناه).

## الخطوات
1. افتح الطرفية داخل مجلد المستودع، وتأكد من الفرع: `git branch --show-current` ⟵ `saai-development`.
2. إن لم يوجد `supabase/config.toml`: `supabase init` (إن سأل عن إعدادات VS Code/IntelliJ فاختر No).
3. في `supabase/config.toml` تأكد من: `[api] schemas = ["public", "graphql_public"]` (بدون `app_private`) و`[auth.email] enable_confirmations = false` (للاختبار المحلي فقط؛ يجب مراجعته قبل الإنتاج).
   - **إصدار PostgreSQL:** اضبط تحت `[db]` القيمة `major_version = 17`. هذا المفتاح (`db.major_version`) يحدّد إصدار PostgreSQL الرئيسي للقاعدة المحلية، ويجب أن يطابق إصدار قاعدتك البعيدة (للتحقق من إصدارها: `SHOW server_version;`). بعض إصدارات الـ CLI تأتي بقيمة افتراضية 15، فإن لم تضبطها فسيتوقف السكربت في الخطوة 0 برسالة تطلب ذلك.
   - بعد تغيير هذه القيمة: `supabase stop` ثم `supabase start`. إن كانت لديك بيئة محلية سابقة بإصدار مختلف وفشل التشغيل، فأرسل لي رسالة الخطأ ولا تحذف شيئًا قبل ذلك.
4. `supabase start` (أول مرة يحمّل صورًا ويستغرق دقائق). في آخره تظهر روابط محلية: API على `http://127.0.0.1:54321` وDB على `postgresql://postgres:postgres@127.0.0.1:54322/postgres`. **تأكد أنها كلها 127.0.0.1.**
5. `bash supabase/tests/local/run_on_supabase_local.sh`
   - يطبع إصدار الخادم (المتوقع PostgreSQL 17 ثم `is_pg17 = t`).
   - يعيد بناء القاعدة من `supabase/migrations/` (`supabase db reset --local`).
   - يعيد تشغيل الترحيل مرة ثانية، ثم ملف الاختبارات، ثم التزامن، ثم حراس الخادم.
   - يحفظ المخرجات في `docs/supabase_local_results/` (نصوص فقط، بلا مفاتيح).
6. بعد الانتهاء: `supabase db reset --local` لإزالة صفوف التزامن، ثم `supabase stop` عند عدم الحاجة.
7. أرسل لي محتوى مجلد `docs/supabase_local_results/` (أو ألصق مخرجات الأمر في الخطوة 5).

## ما الذي ستفحصه هذه الجولة ولم تفحصه جولة PG16
- سلوك R4 على PostgreSQL 17 وعلى مخطط `auth` الحقيقي (أعمدة GoTrue ومشغّلاته).
- هل يعمل `create extension pg_cron` وتُجدول مهمة `saai-gps-purge` فعلًا، وهل يمر الاختبار 180 بوجود `cron.job`.
- هل `supabase db reset --local` يطبّق الملف من أول مرة.
- التزامن مع `auth.users` حقيقي.

## ما لن تفحصه هذه الجولة (يبقى لخطوة لاحقة)
- استدعاء الدوال عبر PostgREST بمفاتيح JWT حقيقية (`rpc`) وأخطاء الواجهة كما تصل للعميل، و`select *` على الجداول ذات الأعمدة المقيّدة. تحتاج رمز مستخدم حقيقي من Auth المحلي، وسأجهّز سكربتًا لها بعد رؤية نتيجة هذه الجولة.
- مجمّع الاتصالات (Supavisor)، والأداء تحت حمل كبير.

## إن فشل شيء
أرسل النص كما هو (مثلًا ملف `03_harness.txt`). لا تعدّل `supabase/migrations/20260101000000_saai_core.sql` بنفسك؛ سأفحص الخطأ وأصلحه وأوثق السبب.
