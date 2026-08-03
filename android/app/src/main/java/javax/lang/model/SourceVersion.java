package javax.lang.model;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/**
 * Minimal stand-in for JDK {@code javax.lang.model.SourceVersion} so that
 * GraphHopper 7.0 can run on Android.
 *
 * <p>GraphHopper's {@code IntEncodedValueImpl.isValidEncodedValue()} calls the
 * static {@code SourceVersion.isKeyword(CharSequence)} to reject encoded-value
 * names that collide with Java keywords. Android's runtime does not ship the
 * {@code java.compiler} module (and thus {@code javax.lang.model}), which made
 * routing fail with
 * {@code Failed resolution of: Ljavax/lang/model/SourceVersion;}.
 *
 * <p>Android's classloader resolves classes from the app APK first for
 * {@code javax.*} packages that are absent from the boot classpath, so this
 * class is picked up instead. Only the static methods referenced by
 * GraphHopper are provided (behavior mirrors the JDK for the subset used).
 */
public class SourceVersion {

    private static final Set<String> KEYWORDS = new HashSet<>(Arrays.asList(
            "abstract", "assert", "boolean", "break", "byte", "case", "catch",
            "char", "class", "const", "continue", "default", "do", "double",
            "else", "enum", "extends", "final", "finally", "float", "for",
            "goto", "if", "implements", "import", "instanceof", "int",
            "interface", "long", "native", "new", "package", "private",
            "protected", "public", "return", "short", "static", "strictfp",
            "super", "switch", "synchronized", "this", "throw", "throws",
            "transient", "try", "void", "volatile", "while", "_",
            "true", "false", "null", "var", "yield", "record", "sealed",
            "permits", "non-sealed", "when", "module", "open", "requires",
            "transitive", "exports", "opens", "to", "uses", "provides", "with"
    ));

    private SourceVersion() {
    }

    /** Returns true if the given string is a Java keyword (case-sensitive). */
    public static boolean isKeyword(CharSequence s) {
        return s != null && KEYWORDS.contains(s.toString());
    }

    /** Returns true if the given string is a valid Java identifier. */
    public static boolean isIdentifier(CharSequence s) {
        if (s == null || s.length() == 0) {
            return false;
        }
        if (!Character.isJavaIdentifierStart(s.charAt(0))) {
            return false;
        }
        for (int i = 1; i < s.length(); i++) {
            if (!Character.isJavaIdentifierPart(s.charAt(i))) {
                return false;
            }
        }
        return !isKeyword(s);
    }

    /** Returns true if the given string is a valid Java qualified name. */
    public static boolean isName(CharSequence s) {
        if (s == null || s.length() == 0) {
            return false;
        }
        String[] parts = s.toString().split("\\.", -1);
        for (String part : parts) {
            if (!isIdentifier(part)) {
                return false;
            }
        }
        return true;
    }
}
