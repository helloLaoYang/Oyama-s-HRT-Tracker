import { describe, expect, it } from 'vitest';
import { readStoredAccount } from '../src/utils/storedAccount';

const storage = (entries: Record<string, string>) => ({
    getItem: (key: string) => entries[key] ?? null,
});

describe('readStoredAccount', () => {
    it('ignores a user record that has no session token', () => {
        expect(
            readStoredAccount(
                storage({
                    auth_user: JSON.stringify({ id: 'sentinel', username: 'not-signed-in' }),
                }),
            ),
        ).toBeNull();
    });

    it('keeps the id and username of a stored session', () => {
        expect(
            readStoredAccount(
                storage({
                    auth_token: 'token',
                    auth_user: JSON.stringify({ id: 'user-1', username: 'ada' }),
                }),
            ),
        ).toEqual({ id: 'user-1', username: 'ada' });
    });

    it('ignores a broken user record', () => {
        expect(readStoredAccount(storage({ auth_token: 'token', auth_user: '{' }))).toBeNull();
    });
});
