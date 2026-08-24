# Drive control authority status

An authenticated Cerebro connection is not proof that the Vision Pro owns ROB's drive input.
The control panel therefore tracks four independent authority states:

- **Control unconfirmed:** the link is verified, but ROB has not named the active controller.
- **Control requesting:** Vision Pro sent `RequestToBeMasterController` and is waiting for ROB.
- **Control granted by robot:** Cerebro's `ROBControlAuthorityStateV1` update names this Vision
  Pro controller ID. This is the only green state and the only state that enables drive input.
- **Control not granted:** Cerebro, autonomy, or another controller was named instead.

An unanswered request returns to unconfirmed after four seconds. Disconnect, emergency stop, and
release clear the local grant. Sending the request successfully never grants control by itself.
