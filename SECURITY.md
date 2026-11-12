# Security

## Reporting a problem

Please don't open a public issue for a security problem. Report it privately instead:
go to the repository's **Security** tab and choose **Report a vulnerability**
(<https://github.com/mrcharlesiv/hermes-hq-app/security/advisories/new>).

Tell us what you found, how to reproduce it, and what someone could do with it. We'll reply as soon as we can.
Please give us a reasonable time to ship a fix before you talk about it in public.

## What's in scope

- The Hermes HQ app for iPhone, iPad and Mac in this repository: how it stores sign-ins and keys, talks to a
  Hermes gateway, handles links, shares files and shows web content.
- The push relay and Connect services the app talks to, where the problem shows up through the app.

The Hermes HQ add-ons have their own repository, [mrcharlesiv/hermes-hq-plugins](https://github.com/mrcharlesiv/hermes-hq-plugins).
Problems in Hermes Agent itself belong with that project.

## Supported versions

Fixes go into the newest release on the App Store, TestFlight and the Mac download. Older builds don't get patches.
