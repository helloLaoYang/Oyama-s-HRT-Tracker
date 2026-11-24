# HRTrace feedback relay

This standalone Cloudflare Worker publishes feedback to the public Issues in
`helloLaoYang/Oyama-s-HRT-Tracker` on behalf of users who do not sign in to
GitHub. The Worker accepts `POST /feedback` with a JSON `title` and `body` and
returns `201` with the Issue `number` and `url` after GitHub creates it.

## Set up the GitHub App

1. [Register a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
   under the account that owns the repository. Use the project's GitHub page
   as its homepage, turn off webhooks, and make the app available only to
   that account. Set **Repository permissions → Issues → Read and write**.
2. [Install it](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app)
   on **Only select repositories**, then choose `Oyama-s-HRT-Tracker`. Open the
   installed app's settings to find the installation ID at the end of the URL.
3. Record the App ID from the registration settings and generate a private key.
   Keep the downloaded PEM outside the repository.

## Deploy the Worker

In a protected JSON file outside the repository, set `GITHUB_APP_ID`,
`GITHUB_APP_INSTALLATION_ID`, and `GITHUB_APP_PRIVATE_KEY` to strings. Use the full
PEM as the private key value, with its newlines represented as `\n` in JSON.
From the repository root, use the installed Wrangler dependency and a
Cloudflare account you control:

```sh
npx wrangler login
npx wrangler deploy --config feedback-worker/wrangler.toml \
  --secrets-file /path/outside/repository/hrtrace-feedback-secrets.json
```

Set the iPhone build's `HRT_FEEDBACK_ENDPOINT_URL` to the deployed HTTPS URL
with `/feedback` appended. See the [native build instructions](../native/README.md#feedback).
