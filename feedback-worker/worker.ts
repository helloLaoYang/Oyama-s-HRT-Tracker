import { createPrivateKey } from 'node:crypto';
import { importPKCS8, SignJWT } from 'jose';

const repositoryName = 'Oyama-s-HRT-Tracker';
const repository = `helloLaoYang/${repositoryName}`;
const maxRequestBytes = 64 * 1024;
const timeoutMs = 6_000;

interface Env {
    GITHUB_APP_ID: string;
    GITHUB_APP_INSTALLATION_ID: string;
    GITHUB_APP_PRIVATE_KEY: string;
    FEEDBACK_PER_IP: RateLimit;
    FEEDBACK_PER_LOCATION: RateLimit;
}

interface Feedback {
    title: string;
    body: string;
}

let cachedInstallationToken: { token: string; expiresAt: number } | undefined;

function error(status: number, code: string, headers?: HeadersInit) {
    return Response.json({ error: code }, { status, headers });
}

async function readRequestText(request: Request): Promise<string | null> {
    const reader = request.body?.getReader();
    if (!reader) {
        return '';
    }

    const decoder = new TextDecoder('utf-8', { fatal: true });
    let bytes = 0;
    let text = '';
    try {
        for (;;) {
            const chunk = await reader.read();
            if (chunk.done) {
                return text + decoder.decode();
            }
            bytes += chunk.value.byteLength;
            if (bytes > maxRequestBytes) {
                await reader.cancel();
                return null;
            }
            text += decoder.decode(chunk.value, { stream: true });
        }
    } finally {
        reader.releaseLock();
    }
}

function parseFeedback(value: unknown): Feedback | null {
    if (
        typeof value !== 'object' ||
        value === null ||
        !('title' in value) ||
        !('body' in value) ||
        typeof value.title !== 'string' ||
        typeof value.body !== 'string'
    ) {
        return null;
    }

    const title = value.title.trim();
    const body = value.body.trim();
    if (!title || [...title].length > 120 || !body || [...body].length > 4_000) {
        return null;
    }
    return { title, body };
}

function postToGitHub(path: string, token: string, body: object) {
    return fetch(`https://api.github.com${path}`, {
        method: 'POST',
        headers: {
            Accept: 'application/vnd.github+json',
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
            'User-Agent': 'HRTrace-Feedback',
            'X-GitHub-Api-Version': '2022-11-28',
        },
        body: JSON.stringify(body),
        redirect: 'error',
        signal: AbortSignal.timeout(timeoutMs),
    });
}

async function installationToken(env: Env, appId: string, installationId: string): Promise<string> {
    if (cachedInstallationToken && cachedInstallationToken.expiresAt > Date.now() + 60_000) {
        return cachedInstallationToken.token;
    }

    // GitHub downloads may use PKCS#1. Convert to the format the Web Crypto key importer expects.
    const pkcs8 = createPrivateKey(env.GITHUB_APP_PRIVATE_KEY).export({ type: 'pkcs8', format: 'pem' });
    const key = await importPKCS8(pkcs8.toString(), 'RS256');
    const now = Math.floor(Date.now() / 1000);
    const jwt = await new SignJWT()
        .setProtectedHeader({ alg: 'RS256' })
        .setIssuer(appId)
        .setIssuedAt(now - 60)
        .setExpirationTime(now + 300)
        .sign(key);

    const response = await postToGitHub(`/app/installations/${installationId}/access_tokens`, jwt, {
        repositories: [repositoryName],
        permissions: { issues: 'write' },
    });
    if (response.status !== 201) {
        throw new Error('Could not create a GitHub installation token');
    }

    const { token, expires_at } = await response.json<{ token?: string; expires_at?: string }>();
    const expiresAt = Date.parse(expires_at ?? '');
    if (typeof token !== 'string' || !token || !(expiresAt > Date.now())) {
        throw new Error('Invalid GitHub installation token response');
    }
    cachedInstallationToken = { token, expiresAt };
    return token;
}

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        if (new URL(request.url).pathname !== '/feedback') {
            return error(404, 'not_found');
        }
        if (request.method !== 'POST') {
            return error(405, 'method_not_allowed', { Allow: 'POST' });
        }
        const contentType = request.headers.get('Content-Type')?.split(';', 1)[0].trim().toLowerCase();
        if (contentType !== 'application/json') {
            return error(415, 'unsupported_media_type');
        }

        try {
            // Cloudflare sets this header at the edge. It is used only for the rate-limit key.
            const ip = request.headers.get('CF-Connecting-IP') ?? 'no-ip';
            const perIP = await env.FEEDBACK_PER_IP.limit({ key: ip });
            if (!perIP.success) {
                return error(429, 'rate_limited', { 'Retry-After': '60' });
            }
            const perLocation = await env.FEEDBACK_PER_LOCATION.limit({ key: 'feedback' });
            if (!perLocation.success) {
                return error(429, 'rate_limited', { 'Retry-After': '60' });
            }
        } catch {
            return error(503, 'service_unavailable');
        }

        let feedback: Feedback | null;
        try {
            const raw = await readRequestText(request);
            if (raw === null) {
                return error(413, 'invalid_feedback');
            }
            feedback = parseFeedback(JSON.parse(raw));
        } catch {
            return error(400, 'invalid_feedback');
        }
        if (!feedback) {
            return error(400, 'invalid_feedback');
        }

        const appId = env.GITHUB_APP_ID?.trim();
        const installationId = env.GITHUB_APP_INSTALLATION_ID?.trim();
        if (!appId || !installationId || !/^\d+$/.test(installationId) || !env.GITHUB_APP_PRIVATE_KEY) {
            return error(503, 'service_unavailable');
        }

        try {
            const token = await installationToken(env, appId, installationId);
            // Render user text literally so GitHub does not resolve mentions or external images.
            const title = feedback.title.replace(/\s+/gu, ' ').replace(/[@#]/g, '$&\u200b');
            const body = feedback.body
                .split(/\r\n?|\n/u)
                .map(line => `    ${line}`)
                .join('\n');
            const issue = await postToGitHub(`/repos/${repository}/issues`, token, { title, body });
            if (issue.status === 401 && cachedInstallationToken?.token === token) {
                cachedInstallationToken = undefined;
            }
            if (issue.status !== 201) {
                return error(502, 'service_unavailable');
            }
            const { number } = await issue.json<{ number?: number }>();
            if (typeof number !== 'number' || !Number.isSafeInteger(number) || number < 1) {
                return error(502, 'service_unavailable');
            }
            return Response.json({ number, url: `https://github.com/${repository}/issues/${number}` }, { status: 201 });
        } catch {
            return error(502, 'service_unavailable');
        }
    },
};
