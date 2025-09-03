# Amount Input Implementation Requirements & Edge Cases

## 📋 **Core Requirements**

### **1. Number Pad Types**
- **`.simple`**: Basic number pad (no special bottom-left button)
- **`.integer`**: Number pad with "000" button for quick input
- **`.decimal`**: Number pad with "." button for decimal input

### **2. Currency Display Modes**
- **Modern Bitcoin**: Integer sats with grouping separators (spaces)
- **Classic Bitcoin**: Decimal BTC with 8 decimal places
- **Fiat**: Decimal currency with 2 decimal places and grouping separators (commas)

### **3. Input Validation**
- **Max Amount**: `999_999_999` sats (≈9.99999999 BTC)
- **Max Length**: 10 digits for modern Bitcoin, 20 for others
- **Max Decimals**: 8 for classic Bitcoin, 2 for fiat
- **Leading Zeros**: Prevented (except for decimal input)

### **4. Display Formatting**
- **Modern Bitcoin**: "100 000" (spaces as grouping separators)
- **Classic Bitcoin**: "1.00000000" (8 decimal places, no trailing zeros)
- **Fiat**: "999,999.00" (commas as grouping separators, always 2 decimals)

### **5. State Management**
- **Primary Display**: Shows selected currency (Bitcoin/Fiat)
- **Secondary Display**: Shows conversion to opposite currency
- **Amount Sats**: Internal representation in satoshis
- **Display Text**: Formatted text for user interface

## 🔍 **Edge Cases & Special Behaviors**

### **1. Decimal Point Handling**
- **Empty input + "."**: Should become "0."
- **Multiple "."**: Should be ignored
- **"0." + delete**: Should clear entire input
- **"1." + delete**: Should become "1"
- **"1.0" + delete**: Should become "1."

### **2. Leading Zero Behavior**
- **"0" + digit**: Should replace "0" with digit
- **"0" + "."**: Should become "0."
- **"0" + delete**: Should clear input
- **"00" + digit**: Should become "0" + digit

### **3. Grouping Separator Handling**
- **Modern Bitcoin**: Remove spaces before parsing, add spaces for display
- **Fiat**: Remove commas before parsing, add commas for display
- **Input with separators**: Should parse correctly (e.g., "1,000" → 1000)

### **4. Max Amount Enforcement**
- **During typing**: Block input when amount would exceed limit
- **Error feedback**: Haptic warning + visual error state
- **Error recovery**: Clear error after 0.5 seconds
- **Partial input**: Don't enforce limit on incomplete numbers (e.g., "999.")

### **5. Currency Toggle Behavior**
- **Bitcoin → Fiat**: Convert sats to fiat with proper formatting
- **Fiat → Bitcoin**: Convert fiat to sats with proper formatting
- **Bitcoin denomination**: Controlled by settings (modern/classic), not by toggle
- **Toggle button**: Shows "Bitcoin" or selected fiat currency name

### **6. Placeholder Behavior**
- **Empty input**: Show appropriate placeholder based on currency
- **During typing**: Show remaining digits/decimals
- **Modern Bitcoin**: No placeholder during typing
- **Classic Bitcoin**: Show ".00000000" when no decimal, remaining "0"s when typing
- **Fiat**: Show ".00" when no decimal, remaining "0"s when typing

### **7. Focus State Handling**
- **Focused**: Placeholder color = textSecondary
- **Unfocused**: Placeholder color = textPrimary
- **Primary amount color**: textPrimary if > 0, textSecondary if 0

### **8. Animation Requirements**
- **Currency toggle**: Smooth transition with spring animation
- **Secondary display**: Move + opacity + scale animation
- **Primary display**: Move + opacity + scale animation

### **9. Haptic Feedback**
- **Button press**: Light haptic feedback
- **Error state**: Warning haptic feedback
- **Max amount exceeded**: Warning haptic feedback

### **10. Input Flow Edge Cases**
- **Delete from formatted text**: Should work correctly
- **Type after delete**: Should continue from correct position
- **Switch currency during input**: Should preserve and convert amount
- **Currency toggle with partial input**: Should properly convert raw input between currencies
- **Delete after currency toggle**: Should work correctly with converted input
- **Conversion accuracy**: Secondary display should show correct converted values

## 🚨 **Critical Edge Cases**

### **1. Number Pad Input Interference**
- **Problem**: Formatting during typing can break input flow
- **Solution**: Separate raw input text from display text

### **2. Max Amount Limit Timing**
- **Problem**: Blocking input when limit exceeded can break user flow
- **Solution**: Block input immediately when limit would be exceeded

### **3. Decimal Precision Loss**
- **Problem**: Double conversion can lose precision
- **Solution**: Use Decimal for calculations, Double for display

### **4. Hardcoded Formatting**
- **Problem**: Different locales use different separators
- **Solution**: Use consistent hardcoded separators (spaces for Bitcoin, commas for fiat)

### **5. Memory Management**
- **Problem**: Large numbers can cause overflow
- **Solution**: Use UInt64 for sats, proper bounds checking

## 🎯 **Implementation Guidelines**

### **1. State Separation**
```swift
@Published var amountSats: UInt64 = 0        // Internal representation
@Published var displayText: String = ""       // Formatted display
private var rawInputText: String = ""        // Raw input for number pad
```

### **2. Input Flow**
1. User presses number pad button
2. `NumberPadInputHandler` processes input
3. Check if new amount would exceed limit
4. If within limit: Update `rawInputText` and `displayText`
5. If exceeds limit: Show error, don't update state

### **3. Error Handling**
- Visual error state (red button highlight)
- Haptic feedback
- Auto-clear error after timeout
- Block input when limit exceeded

## 📝 **Testing Scenarios**

### **Modern Bitcoin Input**
- [ ] Type "100000" → displays "100 000"
- [ ] Type "1000000" → displays "1 000 000"
- [ ] Delete from "100 000" → works correctly
- [ ] Toggle to Fiat → converts to appropriate fiat amount

### **Classic Bitcoin Input**
- [ ] Type "1" → displays "1"
- [ ] Type "1." → displays "1."
- [ ] Type "1.0001" → displays "1.0001"
- [ ] Type "10" → blocked (exceeds limit)
- [ ] Toggle to Fiat → converts to appropriate fiat amount

### **Fiat Input**
- [ ] Type "999999" → displays "999,999.00"
- [ ] Type "999999.5" → displays "999,999.50"
- [ ] Type "1000000" → displays "1,000,000.00"
- [ ] Delete from "999,999.00" → works correctly
- [ ] Toggle to Bitcoin → converts to appropriate sats

### **Edge Case Testing**

#### **Decimal Point Edge Cases**
- [ ] Empty input + "." → "0."
- [ ] "0" + "." → "0."
- [ ] "1" + "." → "1."
- [ ] "1." + "0" → "1.0"
- [ ] "1.0" + "0" → "1.00"
- [ ] "1.00" + "0" → blocked (max decimals reached)
- [ ] Multiple "." → ignored
- [ ] "0." + delete → clears entire input
- [ ] "1." + delete → "1"
- [ ] "1.0" + delete → "1."
- [ ] "1.00" + delete → "1.0"

#### **Leading Zero Edge Cases**
- [ ] "0" + digit → replaces "0" with digit
- [ ] "0" + "." → "0."
- [ ] "0" + delete → clears input
- [ ] "00" + digit → "0" + digit
- [ ] "000" + digit → "0" + digit

#### **Max Amount Edge Cases**
- [ ] Type "999999999" in modern Bitcoin → allowed
- [ ] Type "1000000000" in modern Bitcoin → blocked
- [ ] Type "999999999" in classic Bitcoin → allowed
- [ ] Type "10" in classic Bitcoin → blocked (exceeds limit)
- [ ] Type large amount in fiat → allowed if within 999,999,999 sats limit
- [ ] Type large amount in fiat → blocked if would exceed 999,999,999 sats limit
- [ ] Max amount exceeded → haptic feedback + error state
- [ ] Error state clears after 0.5 seconds

#### **Currency Toggle Edge Cases**
- [ ] Type "100" in modern Bitcoin → toggle to fiat → converts correctly
- [ ] Type "100" in classic Bitcoin → toggle to fiat → converts correctly
- [ ] Type "100" in fiat → toggle to modern Bitcoin → converts correctly
- [ ] Type "100" in fiat → toggle to classic Bitcoin → converts correctly
- [ ] Type "1.5" in classic Bitcoin → toggle to fiat → converts correctly
- [ ] Type "1.50" in fiat → toggle to classic Bitcoin → converts correctly
- [ ] Empty input → toggle → remains empty
- [ ] "0" input → toggle → remains "0"

#### **Delete After Toggle Edge Cases**
- [ ] Type "9" in classic Bitcoin → toggle to fiat → delete to "$0.00" → conversion shows "0.00000000"
- [ ] Type "100" in fiat → toggle to Bitcoin → delete to "0" → conversion shows "0.00"
- [ ] Type "1.5" in classic Bitcoin → toggle to fiat → delete to "$0.00" → conversion shows "0.00000000"
- [ ] Type "1.50" in fiat → toggle to classic Bitcoin → delete to "0" → conversion shows "0.00"

#### **Formatting & Display Edge Cases**
- [ ] Type "1000" in modern Bitcoin → displays "1 000" (spaces)
- [ ] Type "1000" in fiat → displays "1,000.00" (commas + decimals)
- [ ] Delete from formatted text → works correctly
- [ ] Type after delete from formatted text → continues correctly
- [ ] Placeholder shows remaining digits/decimals correctly

#### **UI State Edge Cases**
- [ ] Number pad shown → placeholder color = textSecondary
- [ ] Number pad hidden → placeholder color = textPrimary
- [ ] Amount = 0 → primary amount color = textSecondary
- [ ] Amount > 0 → primary amount color = textPrimary
- [ ] Number pad button press → light haptic feedback
- [ ] Max amount exceeded → warning haptic feedback
- [ ] Error state → warning haptic feedback

#### **Input Flow Edge Cases**
- [ ] Type "100" → delete to "10" → type "5" → "105"
- [ ] Type "1.5" → delete to "1." → type "0" → "1.0"
- [ ] Type "1000" → delete to "100" → type "000" → "100000"
- [ ] Type "1.00" → delete to "1.0" → delete to "1." → delete to "1" → delete to ""
- [ ] Complex delete sequences work correctly

#### **Boundary & Error Edge Cases**
- [ ] Max amount (999,999,999 sats) → allowed in all currencies
- [ ] Amount exceeding max → blocked with error state
- [ ] Max decimals exceeded → blocked (8 for classic Bitcoin, 2 for fiat)
- [ ] Error state → haptic warning + visual feedback
- [ ] Error recovery → auto-clear after 0.5s, or clear on delete/toggle

#### **Performance Edge Cases**
- [ ] Rapid button presses → no lag or input loss
- [ ] Rapid currency toggles → no lag or state corruption
- [ ] Large numbers → no performance degradation
- [ ] Memory usage → no memory leaks during extended use

#### **Known Bug Fixes (Regression Tests)**
- [ ] **Decimal point display**: Type "0." in fiat → decimal point should be textPrimary (white), not textSecondary (gray)
- [ ] **Modern Bitcoin input**: Should allow multiple digits (was limited to 1 digit)
- [ ] **Fiat decimal input**: Type "1.00" → delete should work character by character (was deleting everything after decimal)
- [ ] **Delete after toggle**: Type "10000.00" → toggle currency → delete should work correctly (was deleting everything after decimal point)
- [ ] **Max amount enforcement**: Should block input when limit exceeded, not just prevent conversion
- [ ] **Fiat grouping separators**: Type "999999" → should display "999,999.00" with commas
- [ ] **Placeholder logic**: Type "1" in fiat → should show "1" + ".00" placeholder, not "1.00"

#### **Complex User Journey Tests**
- [ ] **Complete receive flow**: Enter amount → toggle currency → delete partially → continue typing → toggle back → verify final amount
- [ ] **Rapid input**: Type quickly → verify no input loss or lag
- [ ] **Edge case sequence**: Type "0." → toggle → delete → toggle → type "1" → verify correct state
- [ ] **Max amount sequence**: Type "999999999" → try to add "0" → verify blocked → delete → verify can continue
- [ ] **Decimal precision**: Type "1.12345678" in classic Bitcoin → toggle to fiat → verify no precision loss
- [ ] **Zero handling**: Type "0" → toggle → verify stays "0" → delete → verify empty → type "1" → verify works

## 📊 **Test Data & Expected Results**

> **Note**: The edge case lists above provide high-level test scenarios. The detailed test data tables below contain the comprehensive, specific test cases for E2E testing.

### **Modern Bitcoin Test Cases**
| Input | Expected Display | Expected Sats | Notes |
|-------|------------------|---------------|-------|
| "100" | "100" | 100 | Basic input |
| "1000" | "1 000" | 1000 | Grouping separator |
| "1000000" | "1 000 000" | 1000000 | Multiple grouping |
| "999999999" | "999 999 999" | 999999999 | Max amount |
| "1000000000" | Blocked | - | Exceeds max |
| "0" | "0" | 0 | Zero input |
| "" | "" | 0 | Empty input |

### **Classic Bitcoin Test Cases**
| Input | Expected Display | Expected Sats | Notes |
|-------|------------------|---------------|-------|
| "1" | "1" | 100000000 | Basic input |
| "1." | "1." | 0 | Incomplete decimal |
| "1.0" | "1.0" | 100000000 | One decimal |
| "1.00" | "1.00" | 100000000 | Two decimals |
| "1.00000000" | "1.00000000" | 100000000 | Full precision |
| "1.000000001" | Blocked | - | Too many decimals |
| "10" | Blocked | - | Exceeds max amount |
| "0.00000001" | "0.00000001" | 1 | Minimum amount |

### **Fiat Test Cases**
| Input | Expected Display | Expected Sats | Notes |
|-------|------------------|---------------|-------|
| "100" | "100.00" | ~100000000 | Basic input |
| "1000" | "1,000.00" | ~1000000000 | Grouping separator |
| "1000000" | "1,000,000.00" | ~100000000000 | Multiple grouping |
| "1.5" | "1.50" | ~150000000 | Decimal input |
| "1.50" | "1.50" | ~150000000 | Two decimals |
| "1.501" | Blocked | - | Too many decimals |
| Large amount | Blocked if exceeds 999,999,999 sats | - | Depends on conversion rate |

### **Currency Toggle Test Cases**
| From | Input | To | Expected Display | Expected Sats |
|------|-------|----|------------------|---------------|
| Modern BTC | "100" | Fiat | "$X.XX" | 100 |
| Classic BTC | "1.5" | Fiat | "$X.XX" | 150000000 |
| Fiat | "100" | Modern BTC | "100" | ~100000000 |
| Fiat | "1.50" | Classic BTC | "1.50000000" | ~150000000 |

### **Delete Operation Test Cases**
| Before | Delete | After | Notes |
|--------|--------|-------|-------|
| "1000" | 1x | "100" | Basic delete |
| "1 000" | 1x | "100" | Delete from formatted |
| "1.00" | 1x | "1.0" | Delete decimal |
| "1.0" | 1x | "1." | Delete to decimal point |
| "1." | 1x | "1" | Delete decimal point |
| "0." | 1x | "" | Special case |
| "10000.00" | 3x | "10000." | Multiple deletes |

### **Error State Test Cases**
| Action | Expected Result | Recovery |
|--------|----------------|----------|
| Try to exceed max | Haptic warning + error state | Auto-clear after 0.5s |
| Try to input during error | Still blocked | Delete clears error |
| Toggle during error | Error clears | Normal toggle behavior |
| Delete during error | Error clears | Normal delete behavior |

## ⚠️ **Important Notes for Testing**

### **Conversion Rate Dependency**
- **Fiat amounts**: The maximum allowed fiat amount depends on the current Bitcoin price
- **Example**: If 1 BTC = $50,000, then $50,000,000 would be blocked (exceeds 999,999,999 sats)
- **Example**: If 1 BTC = $100,000, then $100,000,000 would be allowed (within 999,999,999 sats)
- **Testing**: Use realistic conversion rates for your test environment
- **Dynamic testing**: Test with different conversion rates to ensure limits work correctly
