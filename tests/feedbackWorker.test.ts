import { generateKeyPairSync } from 'node:crypto';
import { jwtVerify } from 'jose';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const github = vi.fn<typeof fetch>();

function environment() {
    return {
        GITHUB_APP_ID: '12345',
        GITHUB_APP_INSTALLATION_ID: '67890',
        GITHUB_APP_PRIVATE_KEY: privateKey.export({ type: 'pkcs1', format: 'pem' }).toString(),
        FEEDBACK_PER_IP: { limit: vi.fn().mockResolvedValue({ success: true }) },
        FEEDBACK_PER_LOCATION: { limit: vi.fn().mockResolvedValue({ success: true }) },
    };
}

function submit(body: object | string) {
    return new Request('https://localhost/feedback', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.42' },
        body: typeof body === 'string' ? body : JSON.stringify(body),
    });
}

beforeEach(() => {
    vi.resetModules();
    github.mockReset();
    vi.stubGlobal('fetch', github);
});

afterEach(() => vi.unstubAllGlobals());

describe('anonymous feedback relay', () => {
    it('uses a scoped GitHub App token and publishes only literal feedback', async () => {
        const { default: worker } = await import('../feedback-worker/worker');
        const env = environment();
        github
            .mockResolvedValueOnce(
                Response.json(
                    { token: 'installation-token', expires_at: new Date(Date.now() + 3_600_000) },
                    {
                        status: 201,
                    },
                ),
            )
            .mockResolvedValueOnce(Response.json({ number: 42 }, { status: 201 }));
        const draft = {
            title: '  UI issue @octocat #14\n on iOS  ',
            body: '  First line\r\n![pixel](https://example.org/pixel)\n@octocat\n\n```\nLast line  ',
            repository: 'somewhere/else',
            email: 'ignored@example.org',
        };

        const response = await worker.fetch(submit(draft), env);

        expect(response.status).toBe(201);
        expect(await response.json()).toEqual({
            number: 42,
            url: 'https://github.com/helloLaoYang/Oyama-s-HRT-Tracker/issues/42',
        });
        expect(env.FEEDBACK_PER_IP.limit).toHaveBeenCalledWith({ key: '192.0.2.42' });
        expect(github).toHaveBeenCalledTimes(2);

        const [tokenUrl, tokenRequest] = github.mock.calls[0];
        expect(tokenUrl).toBe('https://api.github.com/app/installations/67890/access_tokens');
        expect(JSON.parse(String(tokenRequest?.body))).toEqual({
            repositories: ['Oyama-s-HRT-Tracker'],
            permissions: { issues: 'write' },
        });
        const jwt = new Headers(tokenRequest?.headers).get('Authorization')?.replace(/^Bearer /, '') ?? '';
        const { payload } = await jwtVerify(jwt, publicKey, { issuer: env.GITHUB_APP_ID, algorithms: ['RS256'] });
        const now = Math.floor(Date.now() / 1000);
        expect(payload).toMatchObject({ iat: now - 60, exp: now + 300 });

        const [issueUrl, issueRequest] = github.mock.calls[1];
        expect(issueUrl).toBe('https://api.github.com/repos/helloLaoYang/Oyama-s-HRT-Tracker/issues');
        const headers = new Headers(issueRequest?.headers);
        expect(headers.get('Authorization')).toBe('Bearer installation-token');
        expect(headers.has('CF-Connecting-IP')).toBe(false);
        expect(JSON.parse(String(issueRequest?.body))).toEqual({
            title: 'UI issue @\u200boctocat #\u200b14 on iOS',
            body: '    First line\n    ![pixel](https://example.org/pixel)\n    @octocat\n    \n    ```\n    Last line',
        });
    });

    it('stops rate-limited and invalid submissions before calling GitHub', async () => {
        const { default: worker } = await import('../feedback-worker/worker');
        const env = environment();
        env.FEEDBACK_PER_LOCATION.limit.mockResolvedValueOnce({ success: false });

        const limited = await worker.fetch(submit({ title: 'Title', body: 'Feedback' }), env);
        const invalid = await worker.fetch(submit({ title: '𐀀'.repeat(121), body: 'Feedback' }), env);
        const tooLarge = await worker.fetch(submit(' '.repeat(64 * 1024 + 1)), env);

        expect(limited.status).toBe(429);
        expect(limited.headers.get('Retry-After')).toBe('60');
        expect(invalid.status).toBe(400);
        expect(tooLarge.status).toBe(413);
        expect(github).not.toHaveBeenCalled();
    });

    it('returns a generic error when authentication fails', async () => {
        const { default: worker } = await import('../feedback-worker/worker');
        github.mockResolvedValueOnce(Response.json({ message: 'Upstream error details' }, { status: 403 }));

        const response = await worker.fetch(submit({ title: 'Title', body: 'Feedback' }), environment());

        expect(response.status).toBe(502);
        expect(await response.json()).toEqual({ error: 'service_unavailable' });
        expect(github).toHaveBeenCalledTimes(1);
    });
});
