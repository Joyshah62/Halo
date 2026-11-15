// File storage: bytes go to AWS S3 (public URLs), and a record of each file (its S3 link,
// type, size and context) goes to MongoDB Atlas. Off unless both are configured, so the
// server still runs offline and with HALO_MOCK=1.
import { randomUUID } from "node:crypto";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { MongoClient } from "mongodb";
import { log, errorDetails } from "./logging.js";

export const MAX_FILE_BYTES = 25 * 1024 * 1024;
export const KINDS = new Set(["upload", "document", "note-image", "screenshot"]);
const EXTENSIONS = {
  "application/pdf": "pdf", "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif",
  "audio/mpeg": "mp3", "text/plain": "txt", "application/json": "json",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
  "application/vnd.ms-powerpoint": "ppt", "application/msword": "doc",
};

export class StorageError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

// Public object URL. AWS_S3_PUBLIC_URL overrides it (a CloudFront domain, for example).
export function publicUrl(key, { bucket, region, base } = {}) {
  const path = key.split("/").map(encodeURIComponent).join("/");
  if (base) return `${base.replace(/\/+$/, "")}/${path}`;
  return `https://${bucket}.s3.${region}.amazonaws.com/${path}`;
}

export function objectKey(kind, mime, name, now = new Date()) {
  const fromName = /\.([a-z0-9]{1,8})$/i.exec(String(name || ""))?.[1]?.toLowerCase();
  const ext = EXTENSIONS[mime] || fromName || "bin";
  const day = now.toISOString().slice(0, 10).replaceAll("-", "/");
  return `${kind}/${day}/${randomUUID()}.${ext}`;
}

// `s3` needs send(command); `files` is a MongoDB collection (or anything with insertOne/find).
export function createStorage({ s3, files, bucket, region, base, prefix = "" }) {
  async function store({ data, mime = "application/octet-stream", kind = "upload", name, meta = {} }) {
    if (!KINDS.has(kind)) throw new StorageError(400, `kind must be one of: ${[...KINDS].join(", ")}`);
    if (!Buffer.isBuffer(data) || !data.length) throw new StorageError(400, "The file is empty.");
    if (data.length > MAX_FILE_BYTES) throw new StorageError(413, "Choose a file smaller than 25 MB.");
    const key = prefix + objectKey(kind, mime, name);
    await s3.send(new PutObjectCommand({
      Bucket: bucket, Key: key, Body: data, ContentType: mime,
      ...(name ? { ContentDisposition: `inline; filename="${String(name).replace(/[^\w.\- ]/g, "_").slice(0, 120)}"` } : {}),
    }));
    const record = {
      kind, bucket, key, url: publicUrl(key, { bucket, region, base }),
      mime, size: data.length, name: name ? String(name).slice(0, 200) : null, meta, createdAt: new Date(),
    };
    const { insertedId } = await files.insertOne(record);
    return toJSON({ ...record, _id: insertedId });
  }

  async function list({ kind, limit = 50 } = {}) {
    const query = kind ? { kind } : {};
    const rows = await files.find(query).sort({ createdAt: -1 }).limit(Math.min(Math.max(Number(limit) || 50, 1), 200)).toArray();
    return rows.map(toJSON);
  }

  return { store, list };
}

function toJSON({ _id, ...rest }) {
  return { id: String(_id), ...rest };
}

// ---------- the server's instance, built from the environment ----------
const env = process.env;
export const storageEnabled = Boolean(env.AWS_S3_BUCKET && env.MONGODB_URI) && env.HALO_MOCK !== "1";
let instance = null;

function storage() {
  if (!storageEnabled) throw new StorageError(503, "File storage is off. Set AWS_S3_BUCKET and MONGODB_URI on the Halo server.");
  if (!instance) {
    const region = env.AWS_REGION || "us-east-1";
    // Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY or the usual AWS profile chain.
    const s3 = new S3Client({ region });
    const mongo = new MongoClient(env.MONGODB_URI, { appName: "halo-server" });
    const files = mongo.db(env.MONGODB_DB || "halo").collection(env.MONGODB_COLLECTION || "files");
    files.createIndex({ kind: 1, createdAt: -1 }).catch((error) => log("storage.index.error", errorDetails(error), "warn"));
    instance = createStorage({ s3, files, bucket: env.AWS_S3_BUCKET, region, base: env.AWS_S3_PUBLIC_URL, prefix: env.AWS_S3_PREFIX || "" });
  }
  return instance;
}

export const storeFile = (file) => storage().store(file);
export const listFiles = (options) => storage().list(options);

// For side uploads (screenshots, generated images): never fail the caller, just log and return null.
export async function tryStoreFile(file) {
  if (!storageEnabled) return null;
  try { return await storeFile(file); }
  catch (error) { log("storage.error", { kind: file.kind, ...errorDetails(error) }, "warn"); return null; }
}
