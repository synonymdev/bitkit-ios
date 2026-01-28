## Invoice Scanning & Validation Test Matrix

This document enumerates manual test cases for scanning invoice, the send flow and balance/capacity validation.

Dimensions covered:
- **Invoice type**: onchain (no amount / with amount), lightning (no amount / with amount / expired), unified (BIP21 + lightning, various amounts/expiry)
- **Balances**:
  - Lightning: **0 channels**, **has channels but 0 usable capacity**, **has usable channels + sufficient capacity**, **has usable channels + insufficient capacity**
  - Onchain: **0 onchain balance**, **insufficient onchain balance**, **sufficient onchain balance**

**Note:** If the node is **not running** when scanning, expect the **sync overlay** to appear first. After the node becomes running and validation completes, the behavior matches the test cases below (same as if the node was already running).

---

### Legend

- **LN** = Lightning
- **OC** = Onchain
- **UI** = Unified Invoice (BIP21 + `lightning` param)
- **SS** = Send Sheet

---

## 1. Pure Onchain – No Amount

Sample:  
`bcrt1qmd722klk04yph86ky8jz9gvj6g8n9kjep9zj7d`

| ID | Onchain balance | LN channels / capacity | Expected behavior |
|----|-----------------|------------------------|-------------------|
| OC-NA-1 | **0** | any | **Toast only**, no SS. Toast: insufficient savings (generic). |
| OC-NA-2 | **> 0** | any | **Open SS** with onchain flow. Amount screen (user enters amount). |

---

## 2. Pure Onchain – With Amount

Sample:  
`bitcoin:bcrt1qmd722klk04yph86ky8jz9gvj6g8n9kjep9zj7d?amount=0.000002`

| ID | Onchain balance (vs invoice) | LN channels / capacity | Expected behavior |
|----|------------------------------|------------------------|-------------------|
| OC-A-1 | **insufficient** (bal \< amount) | any | **Toast only**, no SS. Toast: insufficient savings (amount-specific). |
| OC-A-2 | **sufficient** (bal ≥ amount) | any | **Open SS** with onchain flow. Amount screen (user may change amount)  |

---

## 3. Pure Lightning – No Amount

Sample:  
`lnbcrt1p5hnntldqqnp4q2ha8exmazh0ave4mw5gtsdrrdmlh94lkvjmuqceepnxvdmd7z6xupp5euzlz4sj5rk5vn9regdadsrzjq5hdady588p6y8g67n38fryf22ssp5npy5vgmu0ux0szz3uy4awpk7x9dk0p5pd0qct6h4yl6d9z0su8ms9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcgqqqqlgqqqqqqgq2qzpatunvm0yvknery9pdahnkrv0ret48ss74dm8gtgmge3wqy356hx57pkvjhldp0lhqkukameavvd4qfhlcsn0jlkl3vnx3kmsh5nxsq4qhtke`

| ID | LN channels / capacity | Onchain balance | Expected behavior |
|----|------------------------|-----------------|-------------------|
| LN-NA-1 | **0 channels** | any | **Toast only**, no SS. Toast: insufficient spending (generic, since invoice has no amount). |
| LN-NA-2 | **has usable channels, 0 capacity** | any | **Toast only**, no SS. Toast: insufficient spending. |
| LN-NA-3 | **has usable channels, sufficient capacity** | any | **Open SS** with lightning flow. Amount screen (user enters sats). |

---

## 4. Pure Lightning – With Amount

Sample:  
`lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgted72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt`

| ID | LN channels / capacity (vs invoice) | Onchain balance | Expected behavior |
|----|--------------------------------------|-----------------|-------------------|
| LN-A-1 | **0 channels** | any | **Toast only**, no SS. Toast: insufficient spending (amount-specific). |
| LN-A-2 | **has usable channels, insufficient capacity** | any | **Toast only**, no SS. Toast: insufficient spending (amount-specific). |
| LN-A-3 | **has usable channels, sufficient capacity** | any | **Open SS** with lightning flow. Confirm screen. |

---

## 5. Pure Lightning – Expired

Sample:  
`LNBCRT100N1P5H8KFWDQQNP4QDRM0Y4AT84E48QVDN8CSWVE204SF6FFRR3W3AK904GE3JSEGLP4GPP52KT7N4JY7P35N3F27SVX2MWURWPCSEE4TGEY95LH0C2DZ5FG6CMQSP54T60G6XU4EFK70VQLA7E86Q6UZ2ZAFW3X7MAAZ2D8QPF6EVCLRAS9QYYSGQCQPCXQRRSSRZJQ29GJY9SQJRRP48TZ7HJ2E5VM4L2DUKC4CSF2MN6QM32U3HTED5LEAPYQQQQQQQF95QQQQLGQQQQQQGQ2QUNUG6ZUMCH3GVT2LDD3FMAPERZQWMCY0ESN7YFUK6DJH0LG40ZHQCYH8M3L470M3FA8MU78HPT6PVSKC7WGAUJAQAE6PX2A6SHKU4FGQE3X6C5`

| ID | Balances / channels | Expected behavior |
|----|---------------------|-------------------|
| LN-EXP-1 | any | **Toast only**, no SS. Toast: invoice expired. (Handled in `AppViewModel.handleScannedData()`.) |

---

## 6. Unified – Zero Amount

Sample:  
`bitcoin:bcrt1qmd722klk04yph86ky8jz9gvj6g8n9kjep9zj7d?lightning=lnbcrt1p5hnntldqqnp4q2ha8exmazh0ave4mw5gtsdrrdmlh94lkvjmuqceepnxvdmd7z6xupp5euzlz4sj5rk5vn9regdadsrzjq5hdady588p6y8g67n38fryf22ssp5npy5vgmu0ux0szz3uy4awpk7x9dk0p5pd0qct6h4yl6d9z0su8ms9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcgqqqqlgqqqqqqgq2qzpatunvm0yvknery9pdahnkrv0ret48ss74dm8gtgmge3wqy356hx57pkvjhldp0lhqkukameavvd4qfhlcsn0jlkl3vnx3kmsh5nxsq4qhtke`

| ID | LN channels / capacity | Onchain balance | Expected behavior |
|----|------------------------|-----------------|-------------------|
| UI-0A-1 | **has usable channels, sufficient capacity** | any | Prefers LN: **Open SS** with lightning flow. Amount screen (user enters sats). |
| UI-0A-2 | **has usable channels, insufficient capacity** | **0** | LN cannot send → fall back to OC; OC balance 0 → **toast only**, no SS. |
| UI-0A-3 | **has usable channels, insufficient capacity** | **> 0 (sufficient for OC)** | LN cannot send → fall back to OC; OC sufficient → **Open SS** onchain flow (amount/confirm as per design). |
| UI-0A-4 | **0 channels** | **0** | LN cannot send (no channels) → fall back to OC; OC 0 → **toast only**, no SS. |
| UI-0A-5 | **0 channels** | **> 0** | LN cannot send → fall back to OC; OC sufficient → **Open SS** onchain flow. |

---

## 7. Unified – Small Amount

Sample:  
`bitcoin:bcrt1qd2m8c0vdaejjaechgzpwq5gnypkkwzptl5m07v?lightning=lnbcrt2u1p5hnnd3dqqnp4q2ha8exmazh0ave4mw5gtsdrrdmlh94lkvjmuqceepnxvdmd7z6xupp5p0nnjfhz9jkxnefw9e9zf58qw8mk2nqlk9e88vx05h6d9jw0q9xssp5z803k8yqp3r6c4lhjcwrvz0dnl08xmw95lp9shr285c8nury024q9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcgqqqqlgqqqqqqgq2q0krntne8ejg7ee5j8uvv50rzzfwlyjckezmqvd4c9ew7ddslrvwp6fj5vcxxrrukr6n0jfsqc5eggz5g60yhwk3g9hs37272t8uw0yqp7smtl0&amount=0.000002`

| ID | LN capacity (vs LN invoice amount) | OC balance (vs OC amount) | Expected behavior |
|----|-------------------------------------|----------------------------|-------------------|
| UI-SA-1 | **sufficient** | any | LN can send → **Open SS** with lightning flow (confirm). |
| UI-SA-2 | **insufficient** | **sufficient** | LN cannot send → fall back to OC; OC sufficient → **Open SS** with onchain flow (confirm). |
| UI-SA-3 | **insufficient** | **insufficient** | LN cannot send → fall back to OC; OC insufficient → **toast only**, no SS. |
| UI-SA-4 | **0 channels** | **sufficient** | LN cannot send → fall back to OC; OC sufficient → **Open SS** onchain flow. |
| UI-SA-5 | **0 channels** | **insufficient** | LN cannot send → fall back to OC; OC insufficient → **toast only**, no SS. |

---

## 8. Unified – Large Amount

Sample:  
`bitcoin:bcrt1qd2m8c0vdaejjaechgzpwq5gnypkkwzptl5m07v?lightning=lnbcrt2m1p5hnnwvdqqnp4q2ha8exmazh0ave4mw5gtsdrrdmlh94lkvjmuqceepnxvdmd7z6xupp5l5gg9j38pqsql9rzq6vtslhzja90sxczk0ydsawxfklsf2ndftwssp5qpyfd6pdqasn60sexduk07vq67ypqax26xc578jn00739avajaps9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcgqqqqlgqqqqqqgq2qeugggvklr0h4x3g26h3zqttwqknl9vnu8jsrn9mvqhvhvrafefghateuztr74e5y53ftueg8zj7j8vejz8tjzstvm2ruu5m666h78tgpwv4ww0&amount=0.002`

| ID | LN capacity vs LN invoice | OC balance vs OC amount | Expected behavior |
|----|---------------------------|--------------------------|-------------------|
| UI-LA-1 | **sufficient** | any | LN can send → **Open SS** with lightning flow. |
| UI-LA-2 | **insufficient** | **sufficient** | LN insufficient → fall back to OC; OC sufficient → **Open SS** with onchain flow. |
| UI-LA-3 | **insufficient** | **insufficient** | LN insufficient → fall back to OC; OC insufficient → **toast only**, no SS. |

---

## 9. Unified – With Amount – Lightning Expired

Sample:  
`bitcoin:bcrt1qmd722klk04yph86ky8jz9gvj6g8n9kjep9zj7d?amount=0.0000002&lightning=LNBCRT200N1P5H8H4HDQQNP4QDRM0Y4AT84E48QVDN8CSWVE204SF6FFRR3W3AK904GE3JSEGLP4GPP5VCSLQ6RPA2RHQJ40LG6ELHE4JA0548TNQZTX4UFSTKAJ8FAHKLASSP5E2EQTTN20PF2HV7EZQCDKY43DSCVLXXR5LC6E920GDR3GXJ0QYSQ9QYYSGQCQPCXQRRSSRZJQ29GJY9SQJRRP48TZ7HJ2E5VM4L2DUKC4CSF2MN6QM32U3HTED5LEAPYQQQQQQQF95QQQQLGQQQQQQGQ2Q9T08YP2026U697073LS2FRT0EY9MKEYQASUTM5DV9KV5FZS5X2UPPHLFYU4C3Q34LJ8GRTLQ2YG0SWPZJMSK74MV6WHWUEZWG870AHCQGD3XDW`

| ID | Onchain balance vs OC amount | Expected behavior |
|----|------------------------------|-------------------|
| UI-EXP-1 | **insufficient** | Lightning param expired → silently ignore LN, treat as pure onchain. OC insufficient → **toast only**, no SS. |
| UI-EXP-2 | **sufficient** | LN expired → pure onchain; OC sufficient → **Open SS** with onchain flow. |
