/** The bits of a previous sign-in that still affect where records live. */
export interface StoredAccount {
    id: string;
    username: string | null;
}

interface AccountStorage {
    getItem(key: string): string | null;
}

/**
 * A device that was signed in keeps its records under `hrt-u<id>-…`.
 * `auth_user` alone is not a session: the tests and a signed-out browser can
 * leave that key behind without a token, and those records stay on the
 * original `hrt-` keys.
 */
export function readStoredAccount(storage: AccountStorage): StoredAccount | null {
    try {
        const token = storage.getItem('auth_token');
        if (!token) return null;
        const raw = storage.getItem('auth_user');
        if (!raw) return null;
        const parsed = JSON.parse(raw) as { id?: unknown; username?: unknown };
        if (typeof parsed.id !== 'string' || parsed.id.length === 0 || parsed.id.length > 128) return null;
        const username = typeof parsed.username === 'string' ? parsed.username.trim() : '';
        return { id: parsed.id, username: username || null };
    } catch {
        return null;
    }
}
