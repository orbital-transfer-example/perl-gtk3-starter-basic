PO_FILE := po/io.github.orbital-transfer-example.Perl-Gtk3-Starter-Basic.pot
XGETTEXT_PERL_KEYWORDS := -k__ -k\$$__ -k%__ -k__x -k__n:1,2 -k__nx:1,2 -k__xn:1,2 -kN__ -kN__n:1,2 -k__p:1c,2 -k__np:1c,2,3 -kN__p:1c,2 -kN__np:1c,2,3
TRANSLATABLE_PERL_FILES := lib/App/Example.pm

all: $(PO_FILE)

# From <https://www.gnu.org/software/gettext/manual/html_node/Perl.html>
$(PO_FILE): $(TRANSLATABLE_PERL_FILES)
	xgettext \
		$(XGETTEXT_PERL_KEYWORDS) \
		-j -o $@ \
		$<
