#!/bin/bash

xcodebuild test \
  -scheme Bitkit \
  -destination "name=iPhone 16" \
  -only-testing:BitkitTests/PaymentFlowTests/testPaymentFlow \
  GCC_WARN_INHIBIT_ALL_WARNINGS=YES | xcpretty | grep -v "⚠<fe0f>"