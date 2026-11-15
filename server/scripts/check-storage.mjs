// End-to-end storage check: upload through a running Halo server, then confirm the file is
// publicly readable from S3 and its record is in MongoDB Atlas. Cleans up after itself.
//   npm run check:storage                         (server at http://localhost:8787)
//   npm run check:storage -- https://halo-server.onrender.com
import "dotenv/config";
import { MongoClient, ObjectId } from "mongodb";
import { S3Client, DeleteObjectCommand } from "@aws-sdk/client-s3";

const server = (process.argv[2] || `http://localhost:${process.env.PORT || 8787}`).replace(/\/+$/, "");
const ok = (msg) => console.log(`  ✔ ${msg}`);
const fail = (msg) => { console.error(`  ✘ ${msg}`); process.exitCode = 1; };

console.log(`Checking file storage via ${server}\n`);

const health = await fetch(`${server}/api/health`).then((r) => r.json()).catch((e) => fail(`server not reachable: ${e.message}`));
if (!health) process.exit(1);
if (!health.storage) { fail("server reports storage: false (set AWS_S3_BUCKET and MONGODB_URI, HALO_MOCK=0, then restart it)"); process.exit(1); }
ok("server has storage on");

const body = `Halo storage check ${new Date().toISOString()}`;
const res = await fetch(`${server}/api/files?kind=upload&name=halo-storage-check.txt`, { method: "POST", headers: { "Content-Type": "text/plain" }, body });
const reply = await res.json().catch(() => ({}));
if (res.status !== 201) { fail(`upload failed (${res.status}): ${reply.error || "no details"} (the server log has the AWS/Mongo error)`); process.exit(1); }
const file = reply.file;
ok(`uploaded to s3://${file.bucket}/${file.key}`);

const pub = await fetch(file.url);
const text = await pub.text();
if (pub.ok && text === body) ok(`public URL serves the file: ${file.url}`);
else fail(`public URL returned ${pub.status}; the bucket needs public read (Block public access off + s3:GetObject bucket policy)`);

const listed = await fetch(`${server}/api/files?kind=upload&limit=5`).then((r) => r.json());
if (listed.files?.some((f) => f.id === file.id)) ok("GET /api/files lists it");
else fail("GET /api/files does not list the new file");

if (process.env.MONGODB_URI) {
  const mongo = new MongoClient(process.env.MONGODB_URI);
  try {
    const files = mongo.db(process.env.MONGODB_DB || "halo").collection(process.env.MONGODB_COLLECTION || "files");
    const record = await files.findOne({ _id: new ObjectId(file.id) });
    if (record?.url === file.url) ok(`MongoDB record found in ${files.dbName}.${files.collectionName}`);
    else fail("record not found in MongoDB from this machine (is this checker using the same MONGODB_URI as the server?)");
    await files.deleteOne({ _id: new ObjectId(file.id) });
  } catch (e) { fail(`MongoDB: ${e.message}`); }
  finally { await mongo.close(); }
} else console.log("  – MONGODB_URI not set here; skipped the direct MongoDB check");

try {
  await new S3Client({ region: process.env.AWS_REGION || "us-east-1" }).send(new DeleteObjectCommand({ Bucket: file.bucket, Key: file.key }));
  ok("cleaned up the test file");
} catch (e) { console.log(`  – could not delete the test object (${e.name}); remove ${file.key} by hand if you like`); }

console.log(process.exitCode ? "\nStorage check FAILED" : "\nStorage check passed");
