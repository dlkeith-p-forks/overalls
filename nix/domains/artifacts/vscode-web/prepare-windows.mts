import { readFile, writeFile, mkdir, copyFile, rm, readdir } from 'node:fs/promises';
import { join } from 'node:path';

function record(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * @cc [owner:ghuntley,label:build;security] windows-editor-native-target-inputs
 * Native preparation MUST remove the same optional AI backends as Linux, stage
 * only pinned Windows Node/ripgrep executables and preserve the source build's
 * product overlay. Caller paths are private build inputs, never guest authority.
 * @param {string} source
 * @param {string} payload
 * @returns {Promise<void>}
 */
async function prepare(source: string, payload: string): Promise<void> {
    const remote = join(source, 'remote');
    const parsed: unknown = JSON.parse(await readFile(join(remote, 'package.json'), 'utf8'));
    if (!record(parsed) || !record(parsed.dependencies)) {
        throw new Error('invalid_remote_package');
    }
    delete parsed.dependencies['@github/copilot-sdk'];
    delete parsed.dependencies['@vscode/copilot-api'];
    delete parsed.dependencies['@microsoft/mxc-sdk'];
    delete parsed.copilotRuntimeVersion;
    await writeFile(join(remote, 'package.json'), JSON.stringify(parsed));
    const version = (await readFile(join(payload, 'node-version'), 'utf8')).trim();
    if (!/^24\.[0-9]+\.[0-9]+$/.test(version)) { throw new Error('invalid_node_version'); }
    const nodeDirectory = join(source, '.build', 'node', `v${version}`, 'win32-x64');
    await mkdir(nodeDirectory, { recursive: true });
    await copyFile(join(payload, 'node', 'node.exe'), join(nodeDirectory, 'node.exe'));
    for (const base of [source, remote]) {
        const directory = join(base, 'node_modules', '@vscode', 'ripgrep-universal', 'bin');
        await mkdir(join(directory, 'win32-x64'), { recursive: true });
        await copyFile(join(payload, 'ripgrep', 'rg.exe'), join(directory, 'rg.exe'));
        await copyFile(join(payload, 'ripgrep', 'rg.exe'), join(directory, 'win32-x64', 'rg.exe'));
    }
    // Force native compilation; foreign prebuilds cannot become runtime proof.
    await rm(join(remote, 'node_modules', 'node-pty', 'prebuilds'), { recursive: true, force: true });
    // Parcel publishes optional platform packages containing prebuilt watcher
    // binaries. Remove every such package before the offline rebuild so the
    // Windows bundle can only contain the compiler output for this target.
    const remoteModules = join(remote, 'node_modules');
    const moduleEntries = await readdir(remoteModules);
    for (const entry of moduleEntries) {
        if (entry.startsWith('@parcel')) {
            const parcelDirectory = join(remoteModules, entry);
            const parcelEntries = await readdir(parcelDirectory);
            for (const parcelEntry of parcelEntries) {
                if (parcelEntry.startsWith('watcher-')) {
                    await rm(join(parcelDirectory, parcelEntry), { recursive: true, force: true });
                }
            }
        }
    }
    // Some reviewed Code OSS native addons request the optional Visual Studio
    // Spectre library workload. The Windows build image intentionally carries
    // only the standard C++ toolset; remove that optional project preference
    // before node-gyp generates projects, while still compiling every addon
    // from source with the installed compiler.
    const recursiveEntries = await readdir(remoteModules, { recursive: true });
    for (const relative of recursiveEntries) {
        if (relative !== 'binding.gyp' && !relative.endsWith('\\binding.gyp')) { continue; }
        const bindingPath = join(remoteModules, relative);
        const binding = await readFile(bindingPath, 'utf8');
        // Keep the binding's project settings intact while disabling the
        // optional Spectre library requirement. Code OSS packages use both
        // JSON and GYP single-quoted forms, and some put other attributes
        // beside SpectreMitigation. Replacing only the value avoids deleting
        // a surrounding condition or target block.
        const withoutSpectre = binding.replace(
            /(["']SpectreMitigation["']\s*:\s*["'])Spectre(["'])/g,
            '$1false$2',
        );
        if (withoutSpectre !== binding) { await writeFile(bindingPath, withoutSpectre); }
    }
}

const [source, payload, ...extra] = process.argv.slice(2);
if (!source || !payload || extra.length) { throw new Error('invalid_arguments'); }
await prepare(source, payload);
