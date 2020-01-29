Feature: trap lib should mimic trap built-in command
    In order to enhance trap built-in command
    Customers should be able to use same command's options and arguments

    Scenario: using the -l option
        When I run the following script:
            """
            #!/usr/bin/env bash

            source __LIB_DIR__/trap.sh

            if ! diff <(trap -l) <(command trap -l)
            then
                >&2 echo "Using 'trap -l' or 'command trap -l' should be equivalent"
                exit 1
            fi
            """
        Then stdout should be empty
        And stderr should be empty
        And script exit status should be 0

    Scenario: using the -p option
        When I run the following script:
            """
            #!/usr/bin/env bash

            source __LIB_DIR__/trap.sh

            # need to be added after
            trap 'echo "CTRL+C"' SIGINT

            if ! diff <(trap -p) <(command trap -p)
            then
                >&2 echo "Using 'trap -p' or 'command trap -p' should be equivalent"
                exit 1
            fi
            """
        Then stdout should be empty
        And stderr should be empty
        And script exit status should be 0

    Scenario: using "-" for the command argument should clean the corresponding signals
        When I run the following script:
            """
            #!/usr/bin/env bash

            trap 'echo "CTRL+C"' SIGINT

            source __LIB_DIR__/trap.sh

            trap - SIGINT

            if [[ -n "$(trap -p SIGINT)" ]]
            then
                >&2 echo "Signal SIGINT should be empty but contains:"
                >&2 trap -p SIGINT
                exit 1
            fi
            """
        Then stdout should be empty
        And stderr should be empty
        And script exit status should be 0

    Scenario: Option "--" should stop the search for other options
        When I run the following script:
            """
            #!/usr/bin/env bash

            trap 'echo first' SIGINT

            source __LIB_DIR__/trap.sh

            # -l should be interpreted as a command, not an option
            trap -- -p SIGINT

            if [[ -n "$(trap -- -p SIGINT)" ]]
            then
                >&2 echo "'trap -- -p SIGINT' should add command '-p' to the SIGINT signals. Not print the content of the SIGINT signals"
                exit 1
            fi
            """
        Then stdout should be empty
        And stderr should be empty
        And script exit status should be 0

    Scenario: By default, signal(s) must be cleared before adding command.
        When I run the following script:
            """
            #!/usr/bin/env bash

            source __LIB_DIR__/trap.sh

            # need to be added after
            trap 'echo "first"' SIGINT EXIT
            trap 'echo "second"' SIGINT EXIT

            if command trap -p SIGINT | grep -q "first"
            then
                >&2 echo "The first trap command should be removed by the second one (signal: SIGINT)"
                exit 1
            fi

            if command trap -p EXIT | grep -q "first"
            then
                >&2 echo "The first trap command should be removed by the second one (signal: EXIT)"
                exit 1
            fi
            """
        Then stdout should be empty
        And stderr should be empty
        And script exit status should be 0
