import { describe, expect, it } from 'vitest';
import { isNativeAppShell, syncNativeStatusBar, type NativeShellGlobal } from '../src/utils/nativeShell';

describe('native app shell', () => {
    it('recognises Capacitor only when it reports a native platform', () => {
        const native: NativeShellGlobal = { Capacitor: { isNativePlatform: () => true } };
        const browser: NativeShellGlobal = { Capacitor: { isNativePlatform: () => false } };
        expect(isNativeAppShell(native)).toBe(true);
        expect(isNativeAppShell(browser)).toBe(false);
        expect(isNativeAppShell({})).toBe(false);
        expect(isNativeAppShell(undefined)).toBe(false);
    });

    it('treats a broken bridge as a normal browser', () => {
        const broken: NativeShellGlobal = {
            Capacitor: {
                isNativePlatform: () => {
                    throw new Error('bridge unavailable');
                },
            },
        };
        expect(isNativeAppShell(broken)).toBe(false);
    });

    it('does not touch the status bar outside the native shell', () => {
        expect(() => syncNativeStatusBar(true)).not.toThrow();
        expect(() => syncNativeStatusBar(false)).not.toThrow();
    });
});
