import fs from 'node:fs';

const idxPath = process.argv[2];
const idx = JSON.parse(fs.readFileSync(idxPath, 'utf8'));

// Map sha512 -> file entry
const bySha = new Map();
for (const f of idx.files) {
  const h = f.hashes?.sha512;
  if (h) bySha.set(h, f);
}
const hashes = [...bySha.keys()];
console.log('files:', idx.files.length, 'with sha512:', hashes.length);

async function post(url, body) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'user-agent': 'mtrdrgzcid/pack-audit' },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${url} -> ${r.status} ${await r.text()}`);
  return r.json();
}

// 1. hashes -> versions (bulk, chunked)
const versions = {};
for (let i = 0; i < hashes.length; i += 100) {
  const chunk = hashes.slice(i, i + 100);
  const res = await post('https://api.modrinth.com/v2/version_files', {
    hashes: chunk,
    algorithm: 'sha512',
  });
  Object.assign(versions, res);
}
console.log('resolved versions:', Object.keys(versions).length);

// 2. project ids -> project metadata (bulk)
const projIds = [...new Set(Object.values(versions).map((v) => v.project_id))];
const projects = [];
for (let i = 0; i < projIds.length; i += 100) {
  const chunk = projIds.slice(i, i + 100);
  const r = await fetch(
    `https://api.modrinth.com/v2/projects?ids=${encodeURIComponent(JSON.stringify(chunk))}`,
    { headers: { 'user-agent': 'mtrdrgzcid/pack-audit' } }
  );
  if (!r.ok) throw new Error(`projects -> ${r.status}`);
  projects.push(...(await r.json()));
}
const byId = new Map(projects.map((p) => [p.id, p]));
console.log('resolved projects:', byId.size);

const rows = [];
for (const [sha, file] of bySha) {
  const v = versions[sha];
  const p = v ? byId.get(v.project_id) : null;
  rows.push({
    path: file.path,
    slug: p?.slug ?? '(unresolved)',
    title: p?.title ?? '(unresolved)',
    client: p?.client_side ?? '?',
    server: p?.server_side ?? '?',
    packServer: file.env?.server ?? '(none)',
    url: file.downloads?.[0] ?? '',
    size: file.fileSize ?? 0,
  });
}

rows.sort((a, b) => a.slug.localeCompare(b.slug));

const drop = rows.filter((r) => r.server === 'unsupported');
const optional = rows.filter((r) => r.server === 'optional');
const req = rows.filter((r) => r.server === 'required');
const unknown = rows.filter((r) => !['unsupported', 'optional', 'required'].includes(r.server));

console.log('\n=== server_side: unsupported (MUST DROP) ===');
for (const r of drop) console.log(`  ${r.slug.padEnd(34)} ${r.title}`);
console.log('\n=== server_side: optional ===');
for (const r of optional) console.log(`  ${r.slug.padEnd(34)} ${r.title}`);
console.log('\n=== server_side: unknown/unresolved ===');
for (const r of unknown) console.log(`  ${r.slug.padEnd(34)} ${r.title}  (${r.path})`);
console.log(
  `\ntotals: required=${req.length} optional=${optional.length} unsupported=${drop.length} unknown=${unknown.length}`
);

fs.writeFileSync(
  process.argv[3],
  JSON.stringify({ rows, drop: drop.map((r) => r.path), optional: optional.map((r) => r.path) }, null, 2)
);
console.log('\nwrote', process.argv[3]);
