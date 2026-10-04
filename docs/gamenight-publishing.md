# Publishing to GameNight

Successful trusted builds can upload directly to GameNight using the pinned public publishing action. Pull requests never receive publishing credentials. Builds go to **preview**; a developer tests the build and selects **Publish to gamers** in the portal. Existing releases remain available for rollback.

1. Sign in to the [developer portal](https://gamenight.ontola.io/developers/publishing). Ask the GameNight operator to register ownership of an existing catalog game; new games start with an owned submission.
2. Create an upload-only API key for this game. Save the one-time secret immediately.
3. In GitHub Settings → Environments, create an environment named `gamenight`. Add an environment secret named `GAMENIGHT_API_TOKEN` with the game's key. Limit deployment branches to trusted release refs.
4. Once ownership, runtime metadata and keys are configured, set repository Actions variable `GAMENIGHT_PUBLISH_ENABLED` to `true`.
5. Push a trusted release. Open the portal link in the publishing job summary, download and test the private preview, then publish the selected platform build. Production publication requires approved distribution.

The publishing workflow downloads the package from the successful source workflow run, without rebuilding it. It does not run code from the triggering revision in a privileged publishing job.

Rotate keys by creating a replacement, updating the GitHub environment secret, then revoking the old key. Keep upload-only keys for ordinary CI; create a publish-capable key only if intentionally automating production releases. Never put secrets in repository files or command arguments.

See the [canonical publishing guide](https://gamenight.ontola.io/docs/publishing) for the standalone Python uploader, direct HTTPS/S3 imports, private previews, immutable version rules, supported packages and rollback. Paid pricing is an interest submission; live downloads remain free.

