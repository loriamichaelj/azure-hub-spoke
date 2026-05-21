# Hub-and-Spoke Virtual Network Lab

One-paragraph summary: what this is, why it exists, what it demonstrates.

## Architecture
[diagram]
Brief prose walking the reader through it.

## Design decisions
- Why hub-and-spoke vs. mesh vs. flat
- Why jump host vs. Bastion (cost)
- Why no spoke-to-spoke peering
- IP plan rationale

## NSG rules
Table per NSG, with the "why" for each rule.

## Deploy
    ./deploy.sh
Prereqs: az CLI logged in, ssh keypair at ~/.ssh/azure_lab.

## Verify
The exact commands from section 3 above, with expected output.

## Cost
Estimated monthly cost broken down by resource. All-stop:
    ./destroy.sh

## Known limitations
- Home IP rotation breaks SSH access; document the manual fix
- No HA, no backup, no monitoring (that's project 5)
- Single region

## Lessons learned
Two or three honest paragraphs. This is the section hiring managers read.