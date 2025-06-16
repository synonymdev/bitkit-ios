#!/bin/bash

xcodebuild test \
  -scheme Bitkit \
  -destination "name=iPhone 16" \
  -only-testing:BitkitTests/PaymentFlowTests/testPaymentFlow \
  -parallel-testing-enabled NO \
  GCC_WARN_INHIBIT_ALL_WARNINGS=YES | xcpretty | grep -v "⚠<fe0f>"