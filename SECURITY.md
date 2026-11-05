# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use **Report a vulnerability** under this repository's *Security* tab, which reaches the maintainers privately.

Include what you found, how to reproduce it, and what it affects (for example the upload, the signing setup on the runner, or the install page). You will get an answer within a few days.

## What this project handles

This repository holds scripts and a GitHub Action. It contains no secrets, hosts or accounts; those live in each user's `ota.conf` on their own runner. Things worth reporting include:

- a way for the scripts to leak a value from `ota.conf`, the keychain password file or the SSH key, for example into logs;
- a way for input (slug, scheme, paths, IPA contents) to run commands or write outside the intended folders;
- a way for the install page or the generated files to be used against the person installing;
- anything in this repository's own CI that could reach a self-hosted runner.

How to run this safely (private app repositories, runner groups limited to selected repositories, pinning the action to a commit) is in the README under *Security notes*.
