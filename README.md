# Bond Zero - Zero Coupon Bonds using Uniswap V4 Hooks

**Bond Zero splits the yield bearing token into Fixed and variable interest rate**

## Basics

This repository builds a simple zero coupon bond system from first principles, keeping it simple and intuitive for the ETH New Delhi Hackathon

## System components

### YBT

### Principal Token (PT)

### Yield Token (YT)

### Example setup

- Yield Bearing Token (YBT) = 1 unit
- Maturity = 1 year
- APR = 10% simple interest (for simplicity)

According to the above parameter and config, after 1 year, 1 YBT will be worth 1.10 units (Principal + 10% yield)

### Splitting YBT into PT and YT

When YBT is split into PT and YT,

#### PT

- PT can be redeemed for 1 unit of YBT at maturity
- It does not get the 0.10 yield
- The fair value of a PT token today is the present value of 1 unit of YBT due in 1 year.

#### YT

- YT entitles the holder to the 0.10 yield (can be higher/lower than this value) generated over the year.
- The fair value of a YT token today is the present value of the 0.10 yield stream

### PT and YT pricing logic

- Price of PT today
  Price (PT) = 1 / (1 + 0.10 \* 1) = 1/1.1 = 0.909 (approx)

- Price of YT today
  Price (YT) = 0.10 / (1 + 0.10 \* 1) = 0.10 / 1.10 = 0.091 (approx)

- Price of SY = 1 unit = Price (PT) + Price (YT) = 0.900 + 0.091 = 1 unit
