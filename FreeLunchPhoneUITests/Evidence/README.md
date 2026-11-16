# Largest-text scale regression evidence

The historical screenshot shows the Logged sheet after a tap intended for
`plate.scale.startCumulative`. At the largest Dynamic Type size, the partially
covered row reports hittable while the synthesized tap can hit the fixed Log
bar. Main commit `ab2eb43` already scrolls the row above that bar and reveals
End. This PR adds an assertion for the accidental Log action and checks End's
hittability. It introduces no production layout change.

## November 16, 2026 verification blocker

The follow-up on issue dfakkeldy/grok-bots#1201 used a dedicated iPhone 18 Pro,
iOS 27.2, with the simulator gate acquired before compilation and first boot.
A negative control removed only the Start scroll margin, retaining the new
accidental-Log assertion. The project phone test runner compiled and booted
the device, but did not report a test case after announcing Running tests.
The device session remained open after the first boot.

Capacity checks then reported one-minute host loads of 379, 444 and 478,
and zero CPU idle. The stalled run was cancelled and the gate released;
its outcome is not a regression failure or pass. The intended test file was
restored unchanged. Unit tests, a completed negative control and three
consecutive passing scale UI runs remain blocked on host capacity. Earlier
results are historical evidence only and do not fulfill this follow-up.

Resume with an owned phone on a host with capacity. Run the margin-removed
control, restore the intended test, run all package unit tests on the simulator,
and run the largest-text UI test three times without retries or intermediate
shutdowns. Follow the host gate rules before every compile or shutdown-device
boot and close the owned device with shutdown at the end.
