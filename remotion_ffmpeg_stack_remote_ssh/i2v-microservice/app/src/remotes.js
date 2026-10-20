import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import { pool, dbLog } from './db.js';
import { sanitiseName } from './utils.js';

const MOUNT_ROOT   = process.env.MOUNT_ROOT   || '/data/remote';
const SSH_KEY_DIR   = process.env.SSH_KEY_DIR  || '/data/secrets/ssh-keys';
const SMB_CRED_DIR  = process.env.SMB_CRED_DIR || '/data/secrets/smb-creds';
const MOUNT_TIMEOUT = parseInt(process.env.REMOTE_MOUNT_TIMEOUT_MS || '15000');

function run(cmd, args, timeoutMs = MOUNT_TIMEOUT) {
  return new Promise((resolve) => {
    const proc = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const out = [], err = [];
    const timer = setTimeout(() => { proc.kill('SIGKILL'); }, timeoutMs);
    proc.stdout.on('data', d => out.push(d));
    proc.stderr.on('data', d => err.push(d));
    proc.on('close', code => {
      clearTimeout(timer);
      resolve({ code, stdout: Buffer.concat(out).toString(), stderr: Buffer.concat(err).toString() });
    });
    proc.on('error', e => { clearTimeout(timer); resolve({ code: -1, stdout: '', stderr: e.message }); });
  });
}

export function mountPointFor(name) {
  return path.join(MOUNT_ROOT, sanitiseName(name));
}

/**
 * Persist SSH/SMB credentials to disk (never to the DB) with 0600 perms.
 * Returns the secret_ref (filename only) to store on the remotes row.
 */
export async function storeSecret({ protocol, name, authType, password, privateKey, domain, username }) {
  const safe = sanitiseName(name);
  if (protocol === 'ssh') {
    if (authType === 'key') {
      const file = path.join(SSH_KEY_DIR, `${safe}.key`);
      await fs.writeFile(file, privateKey.endsWith('\n') ? privateKey : privateKey + '\n', { mode: 0o600 });
      return `${safe}.key`;
    }
    const file = path.join(SSH_KEY_DIR, `${safe}.pass`);
    await fs.writeFile(file, password, { mode: 0o600 });
    return `${safe}.pass`;
  }
  // smb
  const file = path.join(SMB_CRED_DIR, `${safe}.cred`);
  const lines = [`username=${username || ''}`, `password=${password || ''}`];
  if (domain) lines.push(`domain=${domain}`);
  await fs.writeFile(file, lines.join('\n') + '\n', { mode: 0o600 });
  return `${safe}.cred`;
}

export async function deleteSecret({ protocol, secretRef }) {
  if (!secretRef) return;
  const dir = protocol === 'ssh' ? SSH_KEY_DIR : SMB_CRED_DIR;
  await fs.unlink(path.join(dir, secretRef)).catch(() => {});
}

async function ensureMountPoint(mountPoint) {
  await fs.mkdir(mountPoint, { recursive: true });
}

async function isMounted(mountPoint) {
  const { stdout } = await run('mountpoint', ['-q', mountPoint]).then(
    r => r, () => ({ stdout: '' })
  );
  const r = await run('sh', ['-c', `mountpoint -q '${mountPoint}'`]);
  return r.code === 0;
}

export async function mountRemote(remote) {
  const mountPoint = remote.mount_point || mountPointFor(remote.name);
  await ensureMountPoint(mountPoint);

  if (remote.protocol === 'ssh') {
    const target = `${remote.username}@${remote.host}:${remote.remote_path}`;
    const opts = [
      `port=${remote.port || 22}`,
      'allow_other',
      'reconnect',
      'ServerAliveInterval=15',
      'StrictHostKeyChecking=no',
      'UserKnownHostsFile=/dev/null',
    ];

    if (remote.auth_type === 'key') {
      const keyFile = path.join(SSH_KEY_DIR, remote.secret_ref);
      opts.push(`IdentityFile=${keyFile}`);
      const args = ['-o', opts.join(','), target, mountPoint];
      const res = await run('sshfs', args);
      return finalizeMount(remote, res);
    }

    const passFile = path.join(SSH_KEY_DIR, remote.secret_ref);
    const args = ['-f', passFile, 'sshfs', '-o', [...opts, 'password_stdin'].join(','), target, mountPoint];
    const res = await run('sshpass', args);
    return finalizeMount(remote, res);
  }

  if (remote.protocol === 'smb') {
    const credFile = path.join(SMB_CRED_DIR, remote.secret_ref);
    const unc = `//${remote.host}/${remote.remote_path}`.replace(/\/+/g, '/').replace(':/', '://');
    const optParts = [`credentials=${credFile}`, 'vers=3.0', 'uid=0', 'gid=0', 'file_mode=0644', 'dir_mode=0755'];
    if (remote.domain) optParts.push(`domain=${remote.domain}`);
    const args = ['-t', 'cifs', `//${remote.host}/${remote.remote_path}`, mountPoint, '-o', optParts.join(',')];
    const res = await run('mount', args);
    return finalizeMount(remote, res);
  }

  return { ok: false, error: `Unknown protocol: ${remote.protocol}` };
}

async function finalizeMount(remote, res) {
  if (res.code !== 0) {
    await dbLog('error', `Mount failed for remote "${remote.name}": ${res.stderr.slice(0, 400)}`, null, { remoteId: remote.id });
    return { ok: false, error: res.stderr.slice(0, 400) || 'mount failed' };
  }
  await dbLog('info', `Mounted remote "${remote.name}" (${remote.protocol}) at ${remote.mount_point || mountPointFor(remote.name)}`, null, { remoteId: remote.id });
  return { ok: true };
}

export async function unmountRemote(remote) {
  const mountPoint = remote.mount_point || mountPointFor(remote.name);
  const cmd = remote.protocol === 'ssh' ? 'fusermount' : 'umount';
  const args = remote.protocol === 'ssh' ? ['-u', mountPoint] : [mountPoint];
  const res = await run(cmd, args);
  if (res.code !== 0) {
    await dbLog('warn', `Unmount had issues for "${remote.name}": ${res.stderr.slice(0, 300)}`, null, { remoteId: remote.id });
    return { ok: false, error: res.stderr.slice(0, 300) };
  }
  await dbLog('info', `Unmounted remote "${remote.name}"`, null, { remoteId: remote.id });
  return { ok: true };
}

export async function countMounted() {
  const r = await pool.query(`SELECT COUNT(*) FROM remotes WHERE status='mounted'`);
  return parseInt(r.rows[0].count, 10);
}
