# make -n still runs recipe lines that hold $(MAKE), and release, publish and ship notarize and upload, so they refuse a
# dry run. GNU make 3.81 can put the flags in any word (" --no-print-directory -n"), and make 4 adds "-- VAR=value".
# A dry run is --dry-run, --just-print or --recon, or a short-flag word (only letters after one -) with an n in it.
# make -i (--ignore-errors) goes on after a failed line, so a failed notarization or check could still upload: an i
# in a short-flag word, or --ignore-errors, is refused the same way.
override ndr_letters := a b c d e f g h i j k l m n o p q r s t u v w x y z A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
override ndr_strip = $(if $2,$(call ndr_strip,$(subst $(firstword $2),,$1),$(wordlist 2,$(words $2),$2)),$1)
# the words before a "--" word; the variable assignments after it are not flags
override ndr_flags = $(if $1,$(if $(filter --,$(firstword $1)),,$(firstword $1) $(call ndr_flags,$(wordlist 2,$(words $1),$1))))
# a short-flag word without its one leading -, or nothing for long options and words with digits or other signs
override ndr_short = $(foreach w,$(filter-out --%,$1),$(foreach s,$(patsubst -%,%,$w),$(if $(call ndr_strip,$s,$(ndr_letters)),,$s)))
override ndr_words := $(call ndr_flags,$(MAKEFLAGS))
ifneq (,$(filter release publish ship,$(MAKECMDGOALS)))
ifneq (,$(filter --dry-run --just-print --recon,$(ndr_words))$(findstring n,$(call ndr_short,$(ndr_words))))
$(error release, publish and ship do not run with -n)
endif
ifneq (,$(filter --ignore-errors,$(ndr_words))$(findstring i,$(call ndr_short,$(ndr_words))))
$(error release, publish and ship do not run with -i)
endif
endif
