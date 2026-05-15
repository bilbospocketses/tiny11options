using Tiny11Options.Launcher.Subprocess;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class ArgQuotingTests
{
    [Theory]
    [InlineData(@"C:\Temp\out.iso", @"C:\Temp\out.iso")]                           // no space, no quote -> as-is
    [InlineData(@"C:\Path With Spaces\out.iso", "\"C:\\Path With Spaces\\out.iso\"")] // space -> quoted
    [InlineData("a\"b", "\"a\\\"b\"")]                                              // embedded quote -> escaped + wrapped
    [InlineData("", "\"\"")]                                                        // empty -> quoted-empty
    public void QuoteIfNeeded_HandlesAllPathShapes(string input, string expected)
    {
        Assert.Equal(expected, ArgQuoting.QuoteIfNeeded(input));
    }

    [Fact]
    public void QuoteIfNeeded_NullInput_ReturnsQuotedEmpty()
    {
        Assert.Equal("\"\"", ArgQuoting.QuoteIfNeeded(null));
    }
}
