namespace Sage.Core.Reply;

/// <summary>One piece of Claude's reply, in the order Sage should act on it.</summary>
public abstract record ResponseSegment
{
    /// <summary>Text that's ready to be spoken aloud.</summary>
    public sealed record Speech(string Text) : ResponseSegment;

    /// <summary>A pointing tag. It applies to the speech segment right after it.</summary>
    public sealed record Pointing(PointingTag Tag) : ResponseSegment;

    /// <summary>Claude wants to see the result of the user's next action.</summary>
    public sealed record FollowAlong : ResponseSegment;

    /// <summary>Claude's guess at the control the user will need on the next screen.</summary>
    public sealed record NextStepHint(string Text) : ResponseSegment;
}
