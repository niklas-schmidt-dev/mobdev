---
name: mobdev-competitor-research
description: Research competing iOS apps on a real iPhone with Mobdev - search the App Store, capture listings, ratings and prices, optionally walk through competitors' onboarding and paywalls, and write a comparison report. Use for "competitor analysis", "compare apps", "market research", "what do other apps in this category do", or paywall and pricing research.
---

# Competitor research on a real iPhone

The App Store and third-party apps only run on a real device, which is what Mobdev drives. Read the
`mobdev` skill first for driving the phone.

## Ground rules

- Never buy, subscribe or start a trial. Stop at the payment sheet and record what it shows.
- Installing free apps downloads them with the user's Apple ID. Ask before installing, and list
  what you installed at the end so the user can remove it.
- Do not create accounts with the user's personal data. Use a test account if they give you one.

## 1. Scope

Agree on the category or search terms, how many competitors (5 to 10 is typical) and what to
compare: pricing model, onboarding, paywall, core features or App Store presentation.

## 2. App Store listings

1. `open_app` "App Store", tap Search, `type_text` the term with `submit: true`.
2. For each result worth including, open its page and capture: name, developer, rating and number of
   ratings, price and in-app purchases, category rank if shown, the first screenshots, and the
   headline claims. `read_screen` gives the text; save a screenshot as evidence (see the
   `mobdev-smoke-test` skill for saving full-size PNGs).
3. Scroll to "Information" for size, age rating and the in-app purchase list with prices.

## 3. Inside the apps (optional, with permission)

Install the selected apps, open each with `open_app`, and walk the first-run flow like a new user.
Record the number of screens before the first value, permission prompts, the sign-up wall and the
paywall: plans, prices, trial length and how it can be dismissed.

## 4. Report

Write a report (Markdown or HTML) with:

- A comparison table: app, rating, ratings count, price model, cheapest plan, trial, paywall
  timing, standout features.
- Screenshots side by side for listings and paywalls.
- Patterns across the category, gaps nobody fills, and three concrete ideas for the user's app.
- Sources and date: prices and rankings change and differ by country.
